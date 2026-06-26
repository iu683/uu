#!/bin/bash
# =================================================================
# wg-easy 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="wg-easy"
BASE_DIR="/opt/wg-easy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和配置信息
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从映射获取 WebUI 端口（默认 51821）
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "51821/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="51821"
    else
        webui_port="N/A"
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

# 部署 wg-easy
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义 wg-easy 参数配置 ======${RESET}"
    echo -e "${RED}注意: 该服务需要管理内核网络模块，确保已具备 NET_ADMIN 权限。${RESET}"

    DETECT_IP=$(get_public_ip)

    # 1. 配置 WebUI 访问端口
    echo -ne "${YELLOW}请输入 Web 面板访问端口 [默认: 51821]: ${RESET}"
    read -r custom_ui_port
    [[ -z "$custom_ui_port" ]] && custom_ui_port="51821"
    if ! [[ "$custom_ui_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 配置 WireGuard UDP 传输端口
    echo -ne "${YELLOW}请输入 WireGuard UDP 传输端口 [默认: 51820]: ${RESET}"
    read -r custom_wg_port
    [[ -z "$custom_wg_port" ]] && custom_wg_port="51820"
    if ! [[ "$custom_wg_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 写入 .env 文件 (v15 仅保留端口映射所需的变量)
    cat <<EOF > "$ENV_FILE"
WEBUI_PORT=${custom_ui_port}
WG_PORT=${custom_wg_port}
EOF

    # 3. 动态生成完全符合 v15 规范的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的高级网络 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - LANG=zh
      - INSECURE=true
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "\${WG_PORT}:51820/udp"
      - "\${WEBUI_PORT}:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 wg-easy...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并创建网络网卡 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}           wg-easy 面板部署成功！               ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}Web 管理面板地址 : http://${DETECT_IP}:${custom_ui_port}${RESET}"
    echo -e "${YELLOW}WireGuard节点端口: ${custom_wg_port} (UDP)${RESET}"
    echo -e "${YELLOW}配置文件存储路径 : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 更新镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载容器
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 wg-easy 容器及自定义双栈网络吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器、双栈桥接网络及 Volume 临时缓存数据已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件目录？(y/n) [默认: N]: ${RESET}"
            read -r clean_data
            [[ -z "$clean_data" ]] && clean_data="N"
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}面板配置目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        DETECT_IP=$(get_public_ip)
        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前状态       : $status"
        echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${WEBUI_PORT}${RESET}"
        echo -e "${YELLOW}WireGuard 端口 : ${WG_PORT} (UDP)"
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到部署配置环境。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  wg-easy  管理面板 ◈     ${RESET}"
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
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
