#!/bin/bash
# =================================================================
# Mosdns Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="mosdns"
BASE_DIR="/opt/mosdns"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 数据挂载本地的宿主机路径
DATA_DIR="$BASE_DIR"

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

# 动态获取容器状态、映射端口和网络配置
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        net_mode="Unknown"
        return 0
    fi
    
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
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

        # 提取网络模式
        net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)

        if [[ "$net_mode" == "host" ]]; then
            webui_port="9099 (Host 模式)"
        else
            # 从容器状态提取端口（容器内部监听的是 9099 端口）
            webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9099/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
            [[ -z "$webui_port" ]] && webui_port="9099"
        fi
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        net_mode="N/A"
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

# 部署 Mosdns
install_rules() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -e "${YELLOW}请选择网络模式:${RESET}"
    echo -e " 1. ${GREEN}Host 模式${RESET} (高性能，推荐，免配置支持 IPv6，直接占用宿主机 53 和 9099 端口)"
    echo -e " 2. ${GREEN}Bridge 模式${RESET} (桥接网络端口映射，可自定义外部端口)"
    echo -ne "${YELLOW}请输入选项 [默认: 1]: ${RESET}"
    read -r net_choice
    [[ -z "$net_choice" ]] && net_choice="1"

    if [[ "$net_choice" == "2" ]]; then
        # 桥接模式自定义端口
        echo -ne "${YELLOW}请输入 DNS 服务访问端口 (UDP/TCP 宿主机端口) [默认: 53]: ${RESET}"
        read -r custom_dns_port
        [[ -z "$custom_dns_port" ]] && custom_dns_port="53"

        echo -ne "${YELLOW}请输入 HTTP API 控制台访问端口 (TCP 宿主机端口) [默认: 9099]: ${RESET}"
        read -r custom_http_port
        [[ -z "$custom_http_port" ]] && custom_http_port="9099"

        # 写入环境配置
        cat <<EOF > "$ENV_FILE"
MOSDNS_NET_MODE=bridge
DNS_PORT=${custom_dns_port}
HTTP_PORT=${custom_http_port}
EOF

        # 生成 Bridge 模式的 Compose 文件
        echo -e "${YELLOW}正在生成 Bridge 模式的 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  mosdns:
    image: jasonxtt/mosdns-t:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${DNS_PORT}:53/tcp"
      - "\${DNS_PORT}:53/udp"
      - "\${HTTP_PORT}:9099/tcp"
    volumes:
      - "${DATA_DIR}:/cus/mosdns"
EOF
        display_port=$custom_http_port
    else
        # Host 模式配置
        cat <<EOF > "$ENV_FILE"
MOSDNS_NET_MODE=host
EOF
        echo -e "${YELLOW}正在生成 Host 模式的 docker-compose.yml 配置文件...${RESET}"
        cat <<EOF > "$COMPOSE_FILE"
services:
  mosdns:
    image: jasonxtt/mosdns-t:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: host
    environment:
      MOSDNS_CONTAINER_NETWORK_MODE: host
    volumes:
      - "${DATA_DIR}:/cus/mosdns"
EOF
        display_port="9099"
    fi

    # 修改目录权限保证容器读写正常
    chmod -R 777 "$BASE_DIR"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Mosdns 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          Mosdns 部署及启动成功！                  ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}网络运行模式 : $([[ "$net_choice" == "2" ]] && echo "Bridge 桥接" || echo "Host 直连")${RESET}"
    echo -e "${YELLOW}API 控制台   : http://${DETECT_IP}:${display_port}/  (需视配置文件开放情况)${RESET}"
    echo -e "${YELLOW}数据配置路径 : $DATA_DIR${RESET}"
    echo -e "${YELLOW}配置环境文件 : $ENV_FILE${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}提示: 请确保已将自定义的 config.yaml 放置于 $DATA_DIR 目录下，否则容器可能无法正常工作。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_rules() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新 mosdns 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_rules() {
    echo -ne "${YELLOW}确定要卸载并删除 Mosdns 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及数据挂载？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_rules() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_rules() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_rules() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_rules() { 
    echo -e "${CYAN}--- 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}网络模式     : $net_mode"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}控制台端口   : ${webui_port}${RESET}"
    echo -e "${YELLOW}数据挂载路径 : ${DATA_DIR}${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    ◈   Mosdns 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}模式 :${RESET} ${YELLOW}${net_mode}${RESET}"
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
        1) install_rules ;;
        2) update_rules ;;
        3) uninstall_rules ;;
        4) start_rules ;;
        5) stop_rules ;;
        6) restart_rules ;;
        7) logs_rules ;;
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
