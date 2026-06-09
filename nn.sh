#!/bin/bash
# =================================================================
# qBittorrent Docker Compose 管理面板 (最终完美修复版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="qbittorrent"
BASE_DIR="/opt/qbittorrent"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [[ -f "$COMPOSE_FILE" ]]; then
        webui_port=$(grep -E "\-[[:space:]]+[0-9]+:8080" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | tr -d ' -')
        [[ -z "$webui_port" ]] && webui_port="8080"

        torrent_port=$(grep -E "\-[[:space:]]+[0-9]+:6881($|[[:space:]]|\/)" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d ' -')
        [[ -z "$torrent_port" ]] && torrent_port="6881"

        download_dir=$(grep -E -- "- .+/downloads" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | xargs)
        [[ -z "$download_dir" ]] && download_dir="/opt/qbittorrent/downloads"
    else
        webui_port="N/A"
        torrent_port="N/A"
        download_dir="N/A"
    fi
}

# 【已修复】强力密码提取函数
get_qb_password() {
    if [ ! "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo -e "${RED}容器未部署${RESET}"
        return
    fi
    
    local log_pass
    # 放宽匹配条件，移除干扰字符，精准提取最后一行密码
    log_pass=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -iE "temporary password|session:" | tail -n 1 | sed 's/\r//g' | awk '{print $NF}' | tr -d '[:space:].')
    
    if [[ -n "$log_pass" && ! "$log_pass" =~ "session:" && ! "$log_pass" =~ "password" ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${YELLOW}未探测到初始随机密码（可能已被你修改，或日志已被冲刷）${RESET}"
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "你的服务器IP"
}

install_qbittorrent() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 WebUI 访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 Torrent 传输端口 (宿主机端口) [默认: 6881]: ${RESET}"
    read -r custom_p2p_port
    [[ -z "$custom_p2p_port" ]] && custom_p2p_port="6881"

    echo -ne "${YELLOW}请输入宿主机下载绝对路径 [默认: /opt/qbittorrent/downloads]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="/opt/qbittorrent/downloads"

    mkdir -p "$BASE_DIR/config"
    mkdir -p "$custom_download"
    chmod -R 777 "$BASE_DIR/config" "$custom_download"

    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    
    cat <<EOF > "$COMPOSE_FILE"
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8080
      - TORRENTING_PORT=${custom_p2p_port}
    volumes:
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
    ports:
      - ${custom_port}:8080
      - ${custom_p2p_port}:${custom_p2p_port}
      - ${custom_p2p_port}:${custom_p2p_port}/udp
    stop_grace_period: 10s
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 qBittorrent...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${YELLOW}等待容器初始化并同步密码日志 (约10秒)...${RESET}"
    sleep 10

    SHOW_IP=$(get_public_ip)

    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}       qBittorrent Docker 部署成功！${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SHOW_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -ne "${YELLOW}初始临时密码   : ${RESET}"
    get_qb_password
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_download${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
}

update_qbittorrent() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 linuxserver 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    
    echo -e "${YELLOW}正在应用更新并重启容器...${RESET}"
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

uninstall_qbittorrent() {
    echo -ne "${RED}确定要卸载并删除 qBittorrent 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和下载的数据？(y/n): ${RESET}"
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

start_qb() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_qb() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_qb() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_qb() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    SHOW_IP=$(get_public_ip)
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${YELLOW}当前状态      : $status"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SHOW_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}P2P 传输端口   : ${torrent_port} (TCP/UDP)${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : ${download_dir}${RESET}"
    echo -ne "${YELLOW}初始密码探测   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}==================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}        qBittorrent Docker Compose 管理面板        ${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}容器状态 :${RESET} $status"
    echo -e "${GREEN}WebUI端口 :${RESET} ${YELLOW}${webui_port}${RESET}   ${GREEN}P2P端口 :${RESET} ${YELLOW}${torrent_port}${RESET}"
    echo -e "${GREEN}下载目录 :${RESET} ${CYAN}${download_dir}${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}1. 部署/重建 qBittorrent (自定义端口与目录)${RESET}"
    echo -e "${GREEN}2. 启动容器${RESET}"
    echo -e "${GREEN}3. 停止容器${RESET}"
    echo -e "${GREEN}4. 重启容器${RESET}"
    echo -e "${GREEN}5. 查看实时日志${RESET}"
    echo -e "${GREEN}6. 查看当前配置与密码${RESET}"
    echo -e "${GREEN}7. 彻底卸载容器${RESET}"
    echo -e "${YELLOW}8. 一键检查并更新 qBittorrent 镜像${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_qbittorrent ;;
        2) start_qb ;;
        3) stop_qb ;;
        4) restart_qb ;;
        5) logs_qb ;;
        6) show_info ;;
        7) uninstall_qbittorrent ;;
        8) update_qbittorrent ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
