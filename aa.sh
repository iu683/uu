#!/bin/bash
# =================================================================
# LinuxServer WireGuard 工具箱 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="wireguard"
BASE_DIR="/opt/wireguard-ls"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和端口信息
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        wg_port="$WG_SERVER_PORT"
    else
        wg_port="19999"
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

# 部署 WireGuard
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义 WireGuard 参数配置 ======${RESET}"
    
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    DETECT_IP=$(get_public_ip)

    # 1. 配置宿主机对外监听端口
    echo -ne "${YELLOW}请输入宿主机外部监听端口 [默认: 19999]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="19999"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 配置服务器外部 IP / 域名
    echo -ne "${YELLOW}请输入服务器公网 IP 或域名 (SERVERURL) [默认: ${DETECT_IP}]: ${RESET}"
    read -r custom_url
    [[ -z "$custom_url" ]] && custom_url="$DETECT_IP"

    # 3. 配置内部虚拟子网段 (INTERNAL_SUBNET)
    echo -ne "${YELLOW}请输入 VPN 内部虚拟子网段 [默认: 10.13.13.0]: ${RESET}"
    read -r custom_subnet
    [[ -z "$custom_subnet" ]] && custom_subnet="10.13.13.0"

    # 4. 配置初始生成的客户端数量
    echo -ne "${YELLOW}请输入初始生成的客户端(Peers)数量 [默认: 3]: ${RESET}"
    read -r custom_peers
    [[ -z "$custom_peers" ]] && custom_peers="3"

    # 5. 配置客户端使用的 DNS
    echo -ne "${YELLOW}请输入客户端 DNS (PEERDNS) [默认: 1.1.1.1]: ${RESET}"
    read -r custom_dns
    [[ -z "$custom_dns" ]] && custom_dns="1.1.1.1"

    # 6. 配置宿主机数据挂载路径
    echo -ne "${YELLOW}请输入配置数据挂载路径 [默认: /srv/wg-docker/config]: ${RESET}"
    read -r host_config_path
    [[ -z "$host_config_path" ]] && host_config_path="/srv/wg-docker/config"
    mkdir -p "$host_config_path"

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
WG_UID=${CURRENT_UID}
WG_GID=${CURRENT_GID}
WG_SERVER_URL=${custom_url}
WG_SERVER_PORT=${custom_port}
WG_SUBNET=${custom_subnet}
WG_PEERS=${custom_peers}
WG_DNS=${custom_dns}
WG_HOST_CONFIG=${host_config_path}
EOF

    # 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: ${CONTAINER_NAME}
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=\${WG_UID}
      - PGID=\${WG_GID}
      - TZ=Asia/Shanghai
      - SERVERURL=\${WG_SERVER_URL}
      - SERVERPORT=\${WG_SERVER_PORT}
      - INTERNAL_SUBNET=\${WG_SUBNET}
      - PEERS=\${WG_PEERS}
      - PEERDNS=\${WG_DNS}
      - ALLOWEDIPS=0.0.0.0/0,::/0
    volumes:
      - \${WG_HOST_CONFIG}:/config
      - /lib/modules:/lib/modules:ro
    ports:
      - "\${WG_SERVER_PORT}:51820/udp"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 WireGuard...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并生成密钥文件 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}          WireGuard 服务部署成功！               ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}服务监听端口   : ${custom_port} (UDP)${RESET}"
    echo -e "${YELLOW}外部连接域名/IP : ${custom_url}${RESET}"
    echo -e "${YELLOW}内部虚拟网段   : ${custom_subnet}${RESET}"
    echo -e "${YELLOW}初始客户端数量 : ${custom_peers} 个${RESET}"
    echo -e "${YELLOW}客户端配置文件 : ${host_config_path}${RESET}"
    echo -e "${CYAN}提示：你可以在 ${host_config_path} 下找到 peer1, peer2... 的配置和二维码图片。${RESET}"
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
    echo -ne "${YELLOW}确定要卸载并删除 WireGuard 容器吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            if [ -f "$ENV_FILE" ]; then
                source "$ENV_FILE"
                echo -ne "${YELLOW}是否同时删除生成的客户端配置与密钥目录 (${WG_HOST_CONFIG})？(y/n) [默认: N]: ${RESET}"
                read -r clean_data
                [[ -z "$clean_data" ]] && clean_data="N"
                if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                    rm -rf "$WG_HOST_CONFIG"
                    rm -rf "$BASE_DIR"
                    echo -e "${GREEN}所有客户端配置数据及管理脚本目录已彻底清理。${RESET}"
                fi
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
        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前状态       : $status"
        echo -e "${YELLOW}监听连接端口   : ${WG_SERVER_PORT} (UDP)"
        echo -e "${YELLOW}公网公告地址   : ${WG_SERVER_URL}"
        echo -e "${YELLOW}VPN 内部子网   : ${WG_SUBNET}"
        echo -e "${YELLOW}配置下发数量   : ${WG_PEERS} 个"
        echo -e "${YELLOW}配置存储路径   : ${WG_HOST_CONFIG}"
        echo -e "${GREEN}================================================${RESET}"
        if [ -d "$WG_HOST_CONFIG" ]; then
            echo -e "${CYAN}当前已生成的客户端列表如下:${RESET}"
            ls -d "$WG_HOST_CONFIG"/peer* 2>/dev/null | sed 's|.*/||' | sed 's/^/  - /'
        fi
        echo -e "${GREEN}================================================${RESET}"
    else
        echo -e "${RED}未检测到部署配置环境。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  WireGuard 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${wg_port} (UDP)${RESET}"
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
