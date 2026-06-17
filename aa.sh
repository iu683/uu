#!/bin/bash
# =================================================================
# Filebrowser Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="filebrowser"
BASE_DIR="/opt/filebrowser"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 容器运行状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 获取镜像版本
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi

    # 3. 自适应解析 Compose 文件中的配置
    if [[ -f "$COMPOSE_FILE" ]]; then
        # 提取 WebUI 宿主机端口 (处理 - "8081:80" 或 - 8081:80 格式)
        webui_port=$(grep -E "\-[[:space:]]*[\"']?[0-9]+:[0-9]+" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:add:][:space:]"-')
        [[ -z "$webui_port" ]] && webui_port="8081"

        # 优化下载/网盘绝对路径抓取
        download_dir=$(grep -E -- "- .+/srv" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | tr -d '"' | xargs)
        [[ -z "$download_dir" ]] && download_dir="/opt/filebrowser/file"
    else
        webui_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Filebrowser 容器内的 WebUI 初始临时密码
get_fb_password() {
    if [ ! "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo -e "${RED}容器未部署${RESET}"
        return
    fi
    
    local log_pass
    # 适配 Filebrowser 官方日志格式获取随机密码
    log_pass=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i "password is:" | tail -n 1 | awk -F 'password is:' '{print $2}' | tr -d '[:space:].')
    
    if [[ -n "$log_pass" ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${YELLOW}未探测到初始密码（可能已被你修改，或日志已被冲刷）${RESET}"
    fi
}

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
    echo "127.0.0.1" && return 1
}

install_filebrowser() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Filebrowser 访问端口 (宿主机端口) [默认: 8081]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8081"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入宿主机网盘文件存储绝对路径 [默认: /opt/filebrowser/file]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="/opt/filebrowser/file"

    # 防呆设计：提前创建目录与关键数据库文件，防止 Docker 误将其识别为文件夹挂载崩溃
    mkdir -p "$BASE_DIR/config" "$custom_download"
    touch "$BASE_DIR/config/filebrowser.db"
    chmod -R 777 "$BASE_DIR" "$custom_download"

    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    
    cat <<EOF > "$COMPOSE_FILE"
services:
  filebrowser:
    container_name: ${CONTAINER_NAME}
    image: filebrowser/filebrowser:latest
    restart: always
    user: "$(id -u):$(id -g)"
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
    volumes:
      - ${custom_download}:/srv
      - ${BASE_DIR}/config/filebrowser.db:/database/filebrowser.db
      - ${BASE_DIR}/config/settings.json:/config/settings.json
    ports:
      - "${custom_port}:80"
    networks:
      - filebrowser

networks:
  filebrowser:
    driver: bridge
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Filebrowser...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并同步密码日志 (约5秒)...${RESET}"
    sleep 5

    SHOW_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Filebrowser 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}网盘访问地址 : http://${SHOW_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名   : admin${RESET}"
    echo -ne "${YELLOW}初始随机密码 : ${RESET}"
    get_fb_password
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机网盘路径 : $custom_download${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

update_filebrowser() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Filebrowser 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    
    echo -e "${YELLOW}正在应用更新并重启容器...${RESET}"
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

uninstall_filebrowser() {
    echo -ne "${YELLOW}确定要卸载并删除 Filebrowser 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和网盘内的数据？(y/n): ${RESET}"
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

start_fb() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_fb() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_fb() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_fb() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    SHOW_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}网盘访问地址   : http://${SHOW_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机网盘路径 : ${download_dir}${RESET}"
    echo -ne "${YELLOW}初始密码探测   : ${RESET}"
    get_fb_password
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Filebrowser 管理面板       ${RESET}"
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
        1) install_filebrowser ;;
        2) update_filebrowser ;;
        3) uninstall_filebrowser ;;
        4) start_fb ;;
        5) stop_fb ;;
        6) restart_fb ;;
        7) logs_fb ;;
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
