#!/bin/bash
# =================================================================
# EasyTier 虚拟局域网组网工具箱 Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="easytier"
BASE_DIR="/opt/easytier"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if [ ! -c /dev/net/tun ]; then
        echo -e "${RED}错误: 宿主机未启用 TUN 模块，请先运行: modprobe tun ${RESET}"
        exit 1
    fi
}

# 动态获取容器组网状态
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
        net_name="$ET_NET_NAME"
        node_name="${ET_HOSTNAME:-easytier}"
    else
        net_name="N/A"
        node_name="easytier"
    fi
}

# 部署 EasyTier
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义 EasyTier 组网参数配置 ======${RESET}"

    # 1. 镜像选择（增加国内加速镜像支持）
    echo -e "${YELLOW}请选择使用的 Docker 镜像：${RESET}"
    echo -e "  1) 官方镜像 (easytier/easytier:latest)"
    echo -e "  2) 国内加速 (m.daocloud.io/docker.io/easytier/easytier:latest)"
    echo -ne "${YELLOW}请选择 [默认: 1]: ${RESET}"
    read -r img_choice
    [[ -z "$img_choice" ]] && img_choice="1"
    if [[ "$img_choice" == "2" ]]; then
        IMAGE_NAME="m.daocloud.io/docker.io/easytier/easytier:latest"
    else
        IMAGE_NAME="easytier/easytier:latest"
    fi

    # 2. 节点别名（Hostname）配置 -> 解决名字撞车问题的核心
    local default_hostname=$(hostname)
    [[ -z "$default_hostname" ]] && default_hostname="easytier-node"
    echo -ne "${YELLOW}请输入当前节点的自定义别名 (Hostname) [默认: ${default_hostname}]: ${RESET}"
    read -r custom_hostname
    [[ -z "$custom_hostname" ]] && custom_hostname="$default_hostname"

    # 3. 虚拟网络名称配置
    echo -ne "${YELLOW}请输入您的虚拟网络名称 (<用户>) [默认: my_et_net]: ${RESET}"
    read -r net_name
    [[ -z "$net_name" ]] && net_name="my_et_net"

    # 4. 虚拟网络密码配置
    echo -ne "${YELLOW}请输入您的虚拟网络密码 (<密码>) [默认: et_password]: ${RESET}"
    read -r net_secret
    [[ -z "$net_secret" ]] && net_secret="et_password"

    # 5. Peer 节点配置
    echo -e "${YELLOW}\n是否需要连接到其他现有的对等节点 / 公共节点？${RESET}"
    echo -ne "${YELLOW}输入 (y/N) [默认: N，作为主创节点启动]: ${RESET}"
    read -r has_peer
    [[ -z "$has_peer" ]] && has_peer="N"

    peer_command_line=""
    custom_peer=""
    if [[ "$has_peer" == "y" || "$has_peer" == "Y" ]]; then
        echo -ne "${YELLOW}请输入其他节点的公网 IP 和端口 (例如 1.2.3.4:11010): ${RESET}"
        read -r custom_peer
        if [[ -n "$custom_peer" ]]; then
            peer_command_line="-p tcp://${custom_peer}"
        fi
    fi

    # 写入 .env 文件
    cat <<EOF > "$ENV_FILE"
ET_IMAGE=${IMAGE_NAME}
ET_HOSTNAME=${custom_hostname}
ET_NET_NAME=${net_name}
ET_NET_SECRET=${net_secret}
ET_PEER_URL=${custom_peer}
EOF

    # 6. 动态生成包含自定义 hostname 变量的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  easytier:
    image: \${ET_IMAGE}
    hostname: \${ET_HOSTNAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      - TZ=Asia/Shanghai
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /etc/machine-id:/etc/machine-id:ro
    command: -d --network-name \${ET_NET_NAME} --network-secret \${ET_NET_SECRET} ${peer_command_line}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 EasyTier...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器网卡初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}          EasyTier 组网节点部署成功！             ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}节点自定义别名 : ${custom_hostname}${RESET}"
    echo -e "${YELLOW}虚拟网络名称   : ${net_name}${RESET}"
    echo -e "${YELLOW}虚拟网络密码   : ${net_secret}${RESET}"
    if [[ -n "$custom_peer" ]]; then
        echo -e "${YELLOW}已连接对等端   : tcp://${custom_peer}${RESET}"
    else
        echo -e "${YELLOW}节点运行模式   : 独立主创节点（等待其他子节点加入）${RESET}"
    fi
    echo -e "${YELLOW}配置文件存储   : $COMPOSE_FILE${RESET}"
    echo -e "${CYAN}提示：你可以通过执行 [docker exec -it easytier easytier-cli peer] 查看组网拓扑。${RESET}"
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
    echo -ne "${YELLOW}确定要卸载并删除 EasyTier 节点吗？(y/n) [默认: N]: ${RESET}"
    read -r confirm
    [[ -z "$confirm" ]] && confirm="N"
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止，虚拟网卡及宿主机路由已自动释放。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件目录？(y/n) [默认: N]: ${RESET}"
            read -r clean_data
            [[ -z "$clean_data" ]] && clean_data="N"
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}管理及配置环境已彻底清理。${RESET}"
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

# 扩展：直接在查看配置中集成 easytier-cli 节点状态查询
show_info() {
    get_status_info
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        echo -e "${GREEN}================================================${RESET}"
        echo -e "${YELLOW}当前状态       : $status"
        echo -e "${YELLOW}节点自定义别名 : ${ET_HOSTNAME:-easytier}"
        echo -e "${YELLOW}虚拟网络名称   : ${ET_NET_NAME}"
        echo -e "${YELLOW}虚拟网络密码   : ${ET_NET_SECRET}"
        if [[ -n "$ET_PEER_URL" ]]; then
            echo -e "${YELLOW}连接对等节点   : tcp://${ET_PEER_URL}"
        fi
        echo -e "${GREEN}================================================${RESET}"
        if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
            echo -e "${CYAN}当前局域网内的在线 Peer 拓扑树:${RESET}"
            docker exec -it "$CONTAINER_NAME" easytier-cli peer 2>/dev/null
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
    echo -e "${GREEN} ◈  EasyTier 虚拟组网管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}别名 :${RESET} ${CYAN}${node_name}${RESET}"
    echo -e "${GREEN}网络 :${RESET} ${YELLOW}${net_name}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置与拓扑${RESET}"
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
