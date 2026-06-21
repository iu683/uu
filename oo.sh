#!/bin/bash
# =================================================================
# Kaloscope Docker Compose 智能管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="kaloscope"
BASE_DIR="/opt/kaloscope"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8000"
    else
        img_version="${RED}未安装${RESET}"
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

# 处理绝对路径与相对路径转换
get_real_path() {
    local input_path="$1"
    local default_path="$2"
    [[ -z "$input_path" ]] && input_path="$default_path"

    if [[ "$input_path" == "./"* ]]; then
        echo "$BASE_DIR/${input_path#./}"
    else
        echo "$input_path"
    fi
}

# 部署 Kaloscope
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将使用默认推荐路径。${RESET}"
    
    # 路径 1: 工作区/配置目录
    echo -ne "${YELLOW}请输入工作区(workspace)挂载路径 [默认: ./workspace]: ${RESET}"
    read -r input_workspace
    local path_workspace=$(get_real_path "$input_workspace" "./workspace")

    # 路径 2: 下载目录
    echo -ne "${YELLOW}请输入下载(downloads)挂载路径 [默认: ./downloads]: ${RESET}"
    read -r input_downloads
    local path_downloads=$(get_real_path "$input_downloads" "./downloads")

    # 路径 3: 动漫媒体库目录
    echo -ne "${YELLOW}请输入动漫(animes)媒体库挂载路径 [默认: ./animes]: ${RESET}"
    read -r input_animes
    local path_animes=$(get_real_path "$input_animes" "./animes")

    # 自动创建物理目录并修正群晖/Linux常规权限
    echo -e "${YELLOW}正在预创建本地挂载目录...${RESET}"
    for path in "$path_workspace" "$path_downloads" "$path_animes"; do
        mkdir -p "$path"
        chown -R 1026:100 "$path" 2>/dev/null  # 匹配 PUID/PGID
        chmod -R 775 "$path" 2>/dev/null
    done

    echo -e "\n${CYAN}====== 2. 功能与网络配置 ======${RESET}"
    
    # Web 端口
    echo -ne "${YELLOW}请输入 Kaloscope Web 访问端口 [默认: 8000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8000"

    # Aria2 联动开关
    echo -ne "${YELLOW}是否启用内置 Aria2 下载功能？(y/n) [默认: n]: ${RESET}"
    read -r aria_choice
    local enable_aria2="false"
    local port_mapping="- \"${custom_port}:8000\""
    
    if [[ "$aria_choice" == "y" || "$aria_choice" == "Y" ]]; then
        enable_aria2="true"
        # 联动开启时，自动追加 6888 的 TCP 和 UDP 端口映射
        port_mapping="- \"${custom_port}:8000\"
      - \"6888:6888\"
      - \"6888:6888/udp\""
        echo -e "${GREEN}已动态启用 Aria2 及其 6888 监听端口。${RESET}"
    fi

    # 动态生成完美的 docker-compose.yml
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  kaloscope:
    image: kaloscope/kaloscope:latest
    container_name: ${CONTAINER_NAME}
    extra_hosts:
      - host.docker.internal:host-gateway
    environment:
      - PUID=1026
      - PGID=100
      - UMASK=022
      - TZ=Asia/Shanghai
      - AUTO_TLS=false
      - ENABLE_ARIA2=${enable_aria2}
    volumes:
      - ${path_workspace}:/workspace
      - ${path_downloads}:/downloads
      - ${path_animes}:/animes
    ports:
      ${port_mapping}
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Kaloscope...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       Kaloscope 部署成功！       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}Aria2 开启状态 : ${enable_aria2}${RESET}"
    echo -e "${YELLOW}工作区路径     : ${path_workspace}${RESET}"
    echo -e "${YELLOW}下载路径       : ${path_downloads}${RESET}"
    echo -e "${YELLOW}媒体库路径     : ${path_animes}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Kaloscope 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Kaloscope 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Kaloscope
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Kaloscope 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底删除本地主脚本配置目录管理数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}主脚本配置目录已彻底清理。${RESET}"
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
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Kaloscope 管理面板  ◈     ${RESET}"
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
