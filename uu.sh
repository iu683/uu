#!/bin/bash
# =================================================================
# qBittorrent Docker Compose 管理面板
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

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、镜像版本、映射端口和下载目录
get_status_info() {
    # 1. 容器运行状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi


    # 2. 【精准匹配修复】完美剥离特定格式，只留纯版本号
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{ index .Config.Labels "build_version" }}' "$CONTAINER_NAME" 2>/dev/null | sed 's/Linuxserver.io version:- //g' | awk '{print $1}')
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi

    # 3. 【精准修复】自适应解析 Compose 文件中的官方环境变量与目录映射
    if [[ -f "$COMPOSE_FILE" ]]; then
        # 直接抓取官方环境变量 WEBUI_PORT=xxxx
        webui_port=$(grep -E "WEBUI_PORT=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        # 如果由于某种原因没抓到环境变量，则降级兼容原有的端口映射格式抓取
        if [[ -z "$webui_port" ]]; then
            webui_port=$(grep -E "\-[[:space:]]+[0-9]+:[0-9]+" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d ' -')
        fi
        [[ -z "$webui_port" ]] && webui_port="8080"

        # 直接抓取官方环境变量 TORRENTING_PORT=xxxx
        torrent_port=$(grep -E "TORRENTING_PORT=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        if [[ -z "$torrent_port" ]]; then
            torrent_port=$(grep -E "\-[[:space:]]+[0-9]+:[0-9]+" "$COMPOSE_FILE" | tail -n 1 | awk -F ':' '{print $1}' | tr -d ' -')
        fi
        [[ -z "$torrent_port" ]] && torrent_port="6881"

        # 优化下载目录抓取，支持去掉可能存在的双引号或空格
        download_dir=$(grep -E -- "- .+/downloads" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | tr -d '"' | xargs)
        [[ -z "$download_dir" ]] && download_dir="/opt/qbittorrent/downloads"
    else
        webui_port="N/A"
        torrent_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Docker 容器内的 WebUI 临时密码
get_qb_password() {
    if [ ! "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo -e "${RED}容器未部署${RESET}"
        return
    fi
    
    local log_pass
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

    mkdir -p "$BASE_DIR/config" "$custom_download"
    chmod -R 777 "$BASE_DIR/config" "$custom_download"

    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    
    # 【完美重构点】严格遵循官方规范：-p 两侧端口保持一致，并同步下发给环境变量
    cat <<EOF > "$COMPOSE_FILE"
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
      - TZ=Asia/Shanghai
      - WEBUI_PORT=${custom_port}
      - TORRENTING_PORT=${custom_p2p_port}
    volumes:
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
    ports:
      - ${custom_port}:${custom_port}
      - ${custom_p2p_port}:${custom_p2p_port}
      - ${custom_p2p_port}:${custom_p2p_port}/udp
    stop_grace_period: 10s
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 qBittorrent...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并同步密码日志 (约10秒)...${RESET}"
    sleep 10

    SHOW_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     qBittorrent  部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SHOW_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -ne "${YELLOW}初始临时密码   : ${RESET}"
    get_qb_password
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_download${RESET}"
    echo -e "${GREEN}================================${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像版本       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${SHOW_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}P2P 传输端口   : ${torrent_port} (TCP/UDP)${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : ${download_dir}${RESET}"
    echo -ne "${YELLOW}初始密码探测   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      qBittorrent 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${img_version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}   ${GREEN}P2P端口 :${RESET} ${YELLOW}${torrent_port}${RESET}"
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
        1) install_qbittorrent ;;
        2) update_qbittorrent ;;
        3) uninstall_qbittorrent ;;
        4) start_qb ;;
        5) stop_qb ;;
        6) restart_qb ;;
        7) logs_qb ;;
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
