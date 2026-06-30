#!/bin/bash
# =================================================================
# OneBoard Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="onebord"
BASE_DIR="/opt/oneboard"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 动态获取容器状态、映射端口和环境变量配置
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 判断网络模式
        net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
        
        if [[ "$net_mode" == "host" ]]; then
            # Host 模式：从环境变量获取端口
            webui_port=$(docker inspect -f '{{range .Config.Env}}{{if breakout "ONEBORD_PORT=" .}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | sed 's/ONEBORD_PORT=//')
            [[ -z "$webui_port" ]] && webui_port="8866"
            bind_ip="0.0.0.0"
        else
            # Bridge 模式：从端口映射获取端口与绑定 IP
            local port_info=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "8866/tcp"}}{{(index $conf 0).HostIp}}:{{(index $conf 0).HostPort}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
            if [[ -n "$port_info" && "$port_info" == *":"* ]]; then
                bind_ip=$(echo "$port_info" | cut -d':' -f1)
                webui_port=$(echo "$port_info" | cut -d':' -f2)
            else
                bind_ip="0.0.0.0"
                webui_port="8866"
            fi
        fi
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        bind_ip="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
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

# 部署 OneBoard
install_playground() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 选择网络模式
    echo -e "${YELLOW}请选择网络模式:${RESET}"
    echo -e "  1. Host 模式 (推荐，容器与宿主机共享网络，方便监控本地 127.0.0.1 的服务)"
    echo -e "  2. Bridge 模式 (标准端口映射模式，网络隔离更安全)"
    echo -ne "${GREEN}请输入选项 [默认: 1]: ${RESET}"
    read -r net_choice
    [[ -z "$net_choice" ]] && net_choice="1"

    local listen_ip="0.0.0.0"
    if [[ "$net_choice" == "2" ]]; then
        # 1.5 如果是 Bridge 模式，选择绑定 IP 范围
        echo -e "${YELLOW}请选择服务绑定 IP (访问范围):${RESET}"
        echo -e "${GREEN}  1. 仅限本地访问 (绑定 127.0.0.1，公网无法直接访问，更安全)${RESET}"
        echo -e "${GREEN}  2. 允许公网/全网访问 (绑定 0.0.0.0，可通过服务器 IP 直接访问)${RESET}"
        echo -ne "${GREEN}请输入选项 [默认: 2]: ${RESET}"
        read -r ip_choice
        [[ -z "$ip_choice" ]] && ip_choice="2"
        if [[ "$ip_choice" == "1" ]]; then
            listen_ip="127.0.0.1"
        else
            listen_ip="0.0.0.0"
        fi
    fi

    # 2. 配置端口
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 8866]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8866"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 3. 选择数据持久化挂载方式
    echo -e "${YELLOW}请选择数据挂载方式:${RESET}"
    echo -e "${GREEN}  1. Docker 具名卷挂载 (数据由 Docker 引擎统一管理)${RESET}"
    echo -e "${GREEN}  2. 宿主机本地路径挂载 (手动指定数据存放的本地文件夹，如 /root/oneboard/data)${RESET}"
    echo -ne "${GREEN}请输入选项 [默认: 2]: ${RESET}"
    read -r volume_choice
    [[ -z "$volume_choice" ]] && volume_choice="2"

    local volume_line=""
    local volume_declaration=""

    if [[ "$volume_choice" == "2" ]]; then
        echo -ne "${YELLOW}请输入宿主机本地数据挂载绝对路径 [默认: $BASE_DIR/data]: ${RESET}"
        read -r local_data_path
        [[ -z "$local_data_path" ]] && local_data_path="$BASE_DIR/data"
        mkdir -p "$local_data_path"
        chmod -R 777 "$local_data_path" 2>/dev/null
        
        volume_line="- ${local_data_path}:/app/.onebord"
        volume_declaration="" 
    else
        volume_line="- onebord-data:/app/.onebord"
        volume_declaration="volumes:
  onebord-data:"
    fi

    # 修改基础配置目录权限
    chmod -R 777 "$BASE_DIR" 2>/dev/null

    # 4. 动态生成 Docker Compose 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    
    if [[ "$net_choice" == "2" ]]; then
        # Bridge 模式配置
        cat <<EOF > "$COMPOSE_FILE"
services:
  onebord:
    image: ghcr.io/asrtroh-netizen/oneboard:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${listen_ip}:${custom_port}:8866"
    environment:
      ONEBORD_RUNTIME: docker
      ONEBORD_HOST: 0.0.0.0
      ONEBORD_PORT: 8866
      ONEBORD_PROC_ROOT: /host/proc
      ONEBORD_DISK_PATH: /host/root
    volumes:
      ${volume_line}
      - /proc:/host/proc:ro
      - /:/host/root:ro

${volume_declaration}
EOF
    else
        # Host 模式配置
        cat <<EOF > "$COMPOSE_FILE"
services:
  onebord:
    image: ghcr.io/asrtroh-netizen/oneboard:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: host
    environment:
      ONEBORD_RUNTIME: docker
      ONEBORD_HOST: 0.0.0.0
      ONEBORD_PORT: ${custom_port}
      ONEBORD_PROC_ROOT: /host/proc
      ONEBORD_DISK_PATH: /host/root
    volumes:
      ${volume_line}
      - /proc:/host/proc:ro
      - /:/host/root:ro

${volume_declaration}
EOF
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动 OneBoard 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    # 生成展示 IP
    if [[ "$listen_ip" == "127.0.0.1" ]]; then
        DETECT_IP="127.0.0.1"
    else
        RAW_IP=$(get_public_ip)
        DETECT_IP=$(format_ip_for_url "$RAW_IP")
    fi

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}           OneBoard 面板部署成功！              ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    if [[ "$listen_ip" == "127.0.0.1" ]]; then
        echo -e "${RED}提示: 当前绑定了 127.0.0.1，公网无法直接访问，请使用反代或 SSH 隧道。${RESET}"
    fi
    echo -e "${CYAN}🔐 默认登录凭据：${RESET}"
    echo -e "${CYAN}Username / 用户名: admin${RESET}"
    echo -e "${CYAN}Password / 密码  : admin${RESET}"
    echo -e "${RED}警告: 为了您的系统安全，首次登录后请务必立即修改密码！${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新镜像
update_playground() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_playground() {
    echo -ne "${YELLOW}确定要卸载并删除 OneBoard 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有持久化数据及配置？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                docker volume rm oneboard_onebord-data 2>/dev/null
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置目录、本地映射数据与 Docker 卷已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_playground() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_playground() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_playground() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_playground() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    if [[ "$bind_ip" == "127.0.0.1" ]]; then
        DETECT_IP="127.0.0.1"
    else
        RAW_IP=$(get_public_ip)
        DETECT_IP=$(format_ip_for_url "$RAW_IP")
    fi
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}绑定监听 IP  : ${bind_ip}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈  OneBoard 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_playground ;;
        2) update_playground ;;
        3) uninstall_playground ;;
        4) start_playground ;;
        5) stop_playground ;;
        6) restart_playground ;;
        7) logs_playground ;;
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
