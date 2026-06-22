#!/bin/bash
# =================================================================
# Aria2 Docker Compose 管理面板 (Host/Bridge 双模版 & WEBUI可选版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="aria2"
BASE_DIR="/opt/aria2"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    
    local missing_deps=()
    ! command -v wget &> /dev/null && missing_deps+=("wget")
    ! command -v curl &> /dev/null && missing_deps+=("curl")
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}提示: 正在安装缺失的工具 (${missing_deps[*]})...${RESET}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y wget curl
        elif command -v yum &> /dev/null; then
            sudo yum install -y wget curl
        fi
    fi
}

get_public_ip() {
    local mode=${1:-"v4"}
    local ip=""
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 动态获取容器状态、网络模式、映射端口和数据目录
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi

    webui_enabled="true"
    if [[ -f "$COMPOSE_FILE" ]]; then
        # 检查是否关闭了 WEBUI
        if grep -qE "WEBUI=[[:space:]]*[\"']?false[\"']?" "$COMPOSE_FILE"; then
            webui_enabled="false"
        fi

        if grep -qE "network_mode:[[:space:]]*[\"']?host[\"']?" "$COMPOSE_FILE"; then
            if [[ "$webui_enabled" == "true" ]]; then
                webui_port=$(grep -E "WEBUI_PORT=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
                [[ -z "$webui_port" ]] && webui_port="8080"
                webui_port="${webui_port} (Host 主机网络)"
            else
                webui_port="已禁用控制台"
            fi
        else
            if [[ "$webui_enabled" == "true" ]]; then
                webui_port=$(grep -E "\-[[:space:]]*[\"']?[0-9]+:8080" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"-')
                [[ -z "$webui_port" ]] && webui_port="8080"
            else
                webui_port="已禁用控制台"
            fi
        fi

        download_dir=$(grep -E -- "- .+/downloads" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | tr -d '"' | xargs)
        [[ -z "$download_dir" ]] && download_dir="$BASE_DIR/downloads"
    else
        webui_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Aria2 RPC Token
get_aria2_token() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local token=$(grep -E "SECRET=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        echo -e "${GREEN}${token}${RESET}"
    else
        echo -e "${RED}未部署${RESET}"
    fi
}

install_aria2() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/config"

    echo -e "${CYAN}====== 部署模式选择 ======${RESET}"
    echo -e "请选择想要部署的网络模式："
    echo -e "  1) ${GREEN}Host 主机网络模式${RESET} (推荐！BT/PT公网连接性最好，默认占用 8080、6800、32516 端口)"
    echo -e "  2) ${GREEN}Bridge 桥接网络模式${RESET} (允许自定义修改 WebUI 访问端口、RPC 端口及 BT 端口)"
    echo -ne "${YELLOW}请输入选项 [默认 1]: ${RESET}"
    read -r net_mode
    [[ -z "$net_mode" ]] && net_mode="1"

    # 新增：让用户选择是否开启内置 AriaNg 控制台
    echo -ne "${YELLOW}是否开启内置 AriaNg Web 控制台网页？(y/n) [默认: y]: ${RESET}"
    read -r user_webui_choice
    [[ -z "$user_webui_choice" ]] && user_webui_choice="y"
    
    local webui_env_val="true"
    if [[ "$user_webui_choice" == "n" || "$user_webui_choice" == "N" ]]; then
        webui_env_val="false"
        echo -e "${YELLOW}提示：已选择关闭内置网页控制台，后续您需要使用外部 AriaNg 连接该 RPC 节点。${RESET}"
    fi

    local web_port="8080"
    local rpc_port="6800"
    local bt_port="32516"

    # 自定义端口输入逻辑
    if [[ "$net_mode" == "2" ]]; then
        echo -e "${CYAN}====== 自定义桥接端口配置 ======${RESET}"
        if [[ "$webui_env_val" == "true" ]]; then
            echo -ne "${YELLOW}请输入 WebUI 访问端口 [默认: 8080]: ${RESET}"
            read -r web_port
            [[ -z "$web_port" ]] && web_port="8080"
        fi

        echo -ne "${YELLOW}请输入 RPC 通讯端口 [默认: 6800]: ${RESET}"
        read -r rpc_port
        [[ -z "$rpc_port" ]] && rpc_port="6800"

        echo -ne "${YELLOW}请输入 BT/DHT 监听端口 [默认: 32516]: ${RESET}"
        read -r bt_port
        [[ -z "$bt_port" ]] && bt_port="32516"
    else
        web_port="8080"
        rpc_port="6800"
        bt_port="32516"
    fi

    # 通用公共配置项
    echo -ne "${YELLOW}请输入宿主机下载文件存储绝对路径 [默认: $BASE_DIR/downloads]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="$BASE_DIR/downloads"

    echo -ne "${YELLOW}请设置 Aria2 RPC 安全密钥 (Token) [默认: securetoken]: ${RESET}"
    read -r rpc_token
    [[ -z "$rpc_token" ]] && rpc_token="securetoken"

    echo -ne "${YELLOW}请设置磁盘缓存大小 (CACHE) [默认: 128M / 大内存建议512M]: ${RESET}"
    read -r disk_cache
    [[ -z "$disk_cache" ]] && disk_cache="128M"

    # 获取执行脚本用户的 UID/GID 并创建存储目录
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    mkdir -p "$custom_download"
    
    # ========================== 核心：写入选定模板 ==========================
    if [[ "$net_mode" == "1" ]]; then
        # 模板一：Host 模式配置文件
        echo -e "${YELLOW}正在生成 Host 模式 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  aria2:
    image: superng6/aria2:webui-latest
    container_name: ${CONTAINER_NAME}
    network_mode: host
    environment:
      - PUID=${CURRENT_UID}
      - PGID=${CURRENT_GID}
      - TZ=Asia/Shanghai
      - SECRET=${rpc_token}
      - CACHE=${disk_cache}
      - WEBUI=${webui_env_val}
      - WEBUI_PORT=${web_port}
      - RPC_PORT=${rpc_port}
      - BT_PORT=${bt_port}
      - UT=true
      - SMD=true
    volumes:
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
    restart: unless-stopped
EOF
    else
        # 模板二：Bridge 模式配置文件
        echo -e "${YELLOW}正在生成 Bridge 模式 docker-compose.yml 配置文件...${RESET}"
        
        # 动态处理 Bridge 下如果不开启 WEBUI，则不进行 8080 端口映射
        local ports_config=""
        if [[ "$webui_env_val" == "true" ]]; then
            ports_config="- \"${web_port}:8080\"
      - \"${rpc_port}:6800\"
      - \"${bt_port}:${bt_port}\"
      - \"${bt_port}:${bt_port}/udp\""
        else
            ports_config="- \"${rpc_port}:6800\"
      - \"${bt_port}:${bt_port}\"
      - \"${bt_port}:${bt_port}/udp\""
        fi

        cat <<EOF > "$COMPOSE_FILE"
services:
  aria2:
    image: superng6/aria2:webui-latest
    container_name: ${CONTAINER_NAME}
    environment:
      - PUID=${CURRENT_UID}
      - PGID=${CURRENT_GID}
      - TZ=Asia/Shanghai
      - SECRET=${rpc_token}
      - CACHE=${disk_cache}
      - WEBUI=${webui_env_val}
      - WEBUI_PORT=8080
      - RPC_PORT=6800
      - BT_PORT=32516
      - UT=true
      - SMD=true
    volumes:
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
    ports:
      ${ports_config}
    restart: unless-stopped
EOF
    fi
    # =========================================================================

    chmod -R 777 "$BASE_DIR" "$custom_download"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Aria2...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       Aria2 部署成功！        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    if [[ "$webui_env_val" == "true" ]]; then
        echo -e "${YELLOW}WebUI 访问地址 : http://${SERVER_IP}:${web_port}${RESET}"
    else
        echo -e "${RED}WebUI 控制网页 : 已选择禁用内置控制台${RESET}"
    fi
    echo -e "${YELLOW}RPC 服务访问地址: http://${SERVER_IP}:${rpc_port}/jsonrpc${RESET}"
    echo -ne "${YELLOW}RPC 连接密钥   : ${RESET}"
    get_aria2_token
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_download${RESET}"
    if [[ "$net_mode" == "1" ]]; then
        echo -e "${YELLOW}网络部署模式   : Host 主机网络${RESET}"
    else
        echo -e "${YELLOW}网络部署模式   : Bridge 桥接网络模式${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

update_aria2() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！镜像已处于最新状态。${RESET}"
}

uninstall_aria2() {
    echo -ne "${YELLOW}确定要卸载并删除 Aria2 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和已下载的文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_aria2() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_aria2() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_aria2() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_aria2() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SERVER_IP}:${webui_port}${RESET}"
    echo -ne "${YELLOW}RPC 连接密钥   : ${RESET}"
    get_aria2_token
    echo -e "${YELLOW}宿主机下载路径 : ${download_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       ◈ Aria2 管理面板 ◈       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_aria2 ;;
        2) update_aria2 ;;
        3) uninstall_aria2 ;;
        4) start_aria2 ;;
        5) stop_aria2 ;;
        6) restart_aria2 ;;
        7) logs_aria2 ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
