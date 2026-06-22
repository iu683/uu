#!/bin/bash
# =================================================================
# Transmission Docker Compose 管理面板 (Host/Bridge 双模版可选版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="transmission"
BASE_DIR="/opt/transmission"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
WEB_SRC_DIR="$BASE_DIR/web/src"

# GitHub 仓库信息
REPO_API="https://api.github.com/repos/hisproc/transmission-next-ui/releases/latest"

# 代理前缀列表（第一个留空代表直连尝试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    
    local missing_deps=()
    ! command -v unzip &> /dev/null && missing_deps+=("unzip")
    ! command -v wget &> /dev/null && missing_deps+=("wget")
    ! command -v curl &> /dev/null && missing_deps+=("curl")
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}提示: 正在安装缺失的工具 (${missing_deps[*]})...${RESET}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y wget unzip curl
        elif command -v yum &> /dev/null; then
            sudo yum install -y wget unzip curl
        fi
    fi
}

get_public_ip() {
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

    if [[ -f "$COMPOSE_FILE" ]]; then
        # 核心改动：检查 yml 里是否包含 network_mode: host
        if grep -qE "network_mode:[[:space:]]*[\"']?host[\"']?" "$COMPOSE_FILE"; then
            webui_port="9091"
            peer_port="51413 (Host模式)"
        else
            webui_port=$(grep -E "\-[[:space:]]*[\"']?[0-9]+:9091" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"-')
            [[ -z "$webui_port" ]] && webui_port="9091"
            
            peer_port=$(grep -E "\-[[:space:]]*[\"']?[0-9]+:51413" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"-')
            [[ -z "$peer_port" ]] && peer_port="51413"
        fi

        download_dir=$(grep -E -- "- .+/downloads" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | tr -d '"' | xargs)
        [[ -z "$download_dir" ]] && download_dir="$BASE_DIR/downloads"
    else
        webui_port="N/A"
        peer_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Web UI 账号密码
get_transmission_creds() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local username=$(grep -E "USER=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        local password=$(grep -E "PASS=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        echo -e "${GREEN}用户名: ${username} | 密码: ${password}${RESET}"
    else
        echo -e "${RED}未部署${RESET}"
    fi
}

# 核心下载函数
download_with_proxy_pool() {
    local raw_url="$1"
    local output_path="$2"
    local download_success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local final_url="${proxy}${raw_url}"
        if [[ -z "$proxy" ]]; then
            echo -e "${YELLOW}正在尝试直连下载...${RESET}"
        else
            echo -e "${YELLOW}直连失败或不可用，正在通过代理 [ ${proxy} ] 尝试下载...${RESET}"
        fi
        
        if wget --no-check-certificate --timeout=5 --tries=1 -O "$output_path" "$final_url"; then
            echo -e "${GREEN}下载成功！${RESET}"
            download_success=true
            break
        else
            echo -e "${RED}当前下载通道失败，正在切换下一个通道...${RESET}"
        fi
    done

    if [ "$download_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# 智能动态在线获取最新版 Web UI
setup_custom_webui() {
    echo -ne "${YELLOW}是否自动获取并安装最新版 Next-UI 界面？(y/n) [默认: y]: ${RESET}"
    read -r enable_ui
    [[ -z "$enable_ui" ]] && enable_ui="y"

    if [[ "$enable_ui" == "y" || "$enable_ui" == "Y" ]]; then
        echo -e "${CYAN}--- 正在通过 GitHub API 获取最新版本 ---${RESET}"
        
        local api_response=""
        api_response=$(curl -s --connect-timeout 5 "$REPO_API")
        
        local raw_download_url=""
        local version_tag=""

        if [[ -z "$api_response" || "$api_response" == *"message"* ]]; then
            echo -e "${RED}警告: 无法连接到 GitHub API 或触发限制。将启用本地备用静态解析方案。${RESET}"
            raw_download_url="https://github.com/hisproc/transmission-next-ui/releases/download/v0.3.1/release.zip"
            version_tag="v0.3.1 (备用)"
        else
            raw_download_url=$(echo "$api_response" | grep -E '"browser_download_url":' | grep -i '\.zip' | head -n 1 | awk -F '"' '{print $4}')
            version_tag=$(echo "$api_response" | grep -E '"tag_name":' | head -n 1 | awk -F '"' '{print $4}')
        fi

        if [[ -z "$raw_download_url" ]]; then
            echo -e "${RED}❌ 错误: 无法解析到 zip 压缩包下载地址！将回滚使用原生界面。${RESET}"
            return 1
        fi

        echo -e "${GREEN}发现最新版本: ${version_tag}${RESET}"
        
        echo -e "${YELLOW}正在清理旧的 Web 目录...${RESET}"
        rm -rf "$WEB_SRC_DIR"
        mkdir -p "$WEB_SRC_DIR"

        if download_with_proxy_pool "$raw_download_url" "$BASE_DIR/web_ui.zip"; then
            echo -e "${YELLOW}正在智能解压...${RESET}"
            mkdir -p "$BASE_DIR/web_tmp"
            unzip -q "$BASE_DIR/web_ui.zip" -d "$BASE_DIR/web_tmp"
            
            if [ $(ls -A "$BASE_DIR/web_tmp" | wc -l) -eq 1 ] && [ -d "$BASE_DIR/web_tmp/$(ls -A $BASE_DIR/web_tmp)" ]; then
                mv "$BASE_DIR/web_tmp/$(ls -A $BASE_DIR/web_tmp)"/* "$WEB_SRC_DIR/"
            else
                mv "$BASE_DIR/web_tmp"/* "$WEB_SRC_DIR/"
            fi

            rm -rf "$BASE_DIR/web_ui.zip" "$BASE_DIR/web_tmp"
            echo -e "${GREEN}✨ Next-UI (${version_tag}) 静态文件已成功部署！${RESET}"
            return 0
        else
            echo -e "${RED}❌ 严重错误: 所有下载代理通道全部沦陷！将自动回滚为 Transmission 原生界面。${RESET}"
            return 1
        fi
    fi
    return 1
}

install_transmission() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/config" "$BASE_DIR/watch"

    echo -e "${CYAN}====== 部署模式选择 ======${RESET}"
    echo -e "请选择想要部署的网络模式："
    echo -e "  1) ${GREEN}Host 主机网络模式${RESET} (IPv6全通，无端口转发损耗。固定使用宿主机原生 9091 和 51413 端口)"
    echo -e "  2) ${GREEN}Bridge 桥接网络模式${RESET} (传统容器映射。允许自定义修改 Web 访问端口与 Peer 监听端口)"
    echo -ne "${YELLOW}请输入选项 [默认 1]: ${RESET}"
    read -r net_mode
    [[ -z "$net_mode" ]] && net_mode="1"

    local custom_port="9091"
    local peer_port="51413"

    # 如果是 Bridge 模式，则提示用户输入可选自定义端口
    if [[ "$net_mode" == "2" ]]; then
        echo -e "${CYAN}====== 自定义桥接端口配置 ======${RESET}"
        echo -ne "${YELLOW}请输入 Transmission WebUI 访问端口 [默认: 9091]: ${RESET}"
        read -r custom_port
        [[ -z "$custom_port" ]] && custom_port="9091"
        if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
            return
        fi

        echo -ne "${YELLOW}请输入 Transmission Peer 传入端口 [默认: 51413]: ${RESET}"
        read -r peer_port
        [[ -z "$peer_port" ]] && peer_port="51413"
    fi

    # 通用公共配置项
    echo -ne "${YELLOW}请输入宿主机下载文件存储绝对路径 [默认: $BASE_DIR/downloads]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="$BASE_DIR/downloads"

    echo -ne "${YELLOW}请设置 WebUI 登录用户名 [默认: transmission]: ${RESET}"
    read -r ui_user
    [[ -z "$ui_user" ]] && ui_user="transmission"

    echo -ne "${YELLOW}请设置 WebUI 登录密码 [默认: transmission]: ${RESET}"
    read -r ui_pass
    [[ -z "$ui_pass" ]] && ui_pass="transmission"

    # 执行智能化 UI 部署
    setup_custom_webui
    has_custom_ui=$?

    # 获取执行脚本用户的 UID/GID 并创建存储目录
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    mkdir -p "$custom_download"
    
    local env_web_home=""
    local volume_web_src=""
    if [ $has_custom_ui -eq 0 ]; then
        env_web_home="- TRANSMISSION_WEB_HOME=/src"
        volume_web_src="- ${WEB_SRC_DIR}:/src"
    fi

    # ========================== 核心：写入选定的模板 ==========================
    if [[ "$net_mode" == "1" ]]; then
        # 模板一：Host 模式配置文件
        echo -e "${YELLOW}正在生成 Host 模式 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  transmission:
    image: linuxserver/transmission:4.0.0
    container_name: ${CONTAINER_NAME}
    network_mode: host
    environment:
      - PUID=${CURRENT_UID}
      - PGID=${CURRENT_GID}
      - UMASK=022
      ${env_web_home}
      - TZ=Asia/Shanghai
      - USER=${ui_user}
      - PASS=${ui_pass}
    volumes:
      ${volume_web_src}
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
      - ${BASE_DIR}/watch:/watch
    restart: unless-stopped
EOF
    else
        # 模板二：Bridge 模式配置文件（带自定义映射端口）
        echo -e "${YELLOW}正在生成 Bridge 模式 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  transmission:
    image: linuxserver/transmission:4.0.0
    container_name: ${CONTAINER_NAME}
    environment:
      - PUID=${CURRENT_UID}
      - PGID=${CURRENT_GID}
      - UMASK=022
      ${env_web_home}
      - TZ=Asia/Shanghai
      - USER=${ui_user}
      - PASS=${ui_pass}
    volumes:
      ${volume_web_src}
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
      - ${BASE_DIR}/watch:/watch
    ports:
      - "${custom_port}:9091"
      - "${peer_port}:51413"
      - "${peer_port}:51413/udp"
    restart: unless-stopped
EOF
    fi
    # =========================================================================

    chmod -R 777 "$BASE_DIR" "$custom_download"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Transmission...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Transmission 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SERVER_IP}:${custom_port}${RESET}"
    get_transmission_creds
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_download${RESET}"
    if [[ "$net_mode" == "1" ]]; then
        echo -e "${YELLOW}网络部署模式   : Host 主机网络 (原生 9091/51413 端口)${RESET}"
    else
        echo -e "${YELLOW}Peer 传入端口  : $peer_port (Bridge 映射模式)${RESET}"
    fi
    if [ $has_custom_ui -eq 0 ]; then
        echo -e "${GREEN}自定义 Web UI  : 已成功启用并自动挂载最新版${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

update_transmission() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    
    echo -e "${YELLOW}正在检查并更新 WebUI 与核心镜像...${RESET}"
    if grep -q "TRANSMISSION_WEB_HOME" "$COMPOSE_FILE"; then
        setup_custom_webui
    fi

    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器与组件已处于最新状态。${RESET}"
}

uninstall_transmission() {
    echo -ne "${YELLOW}确定要卸载并删除 Transmission 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和下载的种子文件？(y/n): ${RESET}"
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

start_trans() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_trans() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_trans() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_trans() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SERVER_IP}:${webui_port}${RESET}"
    echo -ne "${YELLOW}当前认证凭据   : ${RESET}"
    get_transmission_creds
    echo -e "${YELLOW}宿主机下载路径 : ${download_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈ Transmission 管理面板   ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前状态 :${RESET} $status"
    echo -e "${GREEN}网页端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}传入端口 :${RESET} ${YELLOW}${peer_port}${RESET}"
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
        1) install_transmission ;;
        2) update_transmission ;;
        3) uninstall_transmission ;;
        4) start_trans ;;
        5) stop_trans ;;
        6) restart_trans ;;
        7) logs_trans ;;
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
