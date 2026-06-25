#!/bin/bash
# =================================================================
# Remnawave Subscription Page Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="remnawave-subscription-page"
BASE_DIR="/opt/remnawave-sub"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
NETWORK_NAME="remnawave-network"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和映射端口
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

        # 从容器状态提取 WebUI 端口（容器内部默认监听的是 3010 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3010/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3010"
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

# 部署 Remnawave Subscription Page
install_remnawave_sub() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 场景选择
    echo -e "${YELLOW}请选择您的部署场景:${RESET}"
    echo -e "  ${GREEN}1. 跨服务器部署${RESET} (订阅页与面板不在同一台机器，网络各自独立)"
    echo -e "  ${GREEN}2. 同服务器部署${RESET} (订阅页与面板在同一台机器，共享 Docker 外部网络)"
    echo -ne "${YELLOW}请输入选项 [默认: 1]: ${RESET}"
    read -r scene_choice
    [[ -z "$scene_choice" ]] && scene_choice="1"

    # 根据场景配置网络定义
    local network_config=""
    if [[ "$scene_choice" == "2" ]]; then
        echo -e "${GREEN} -> 已选择同服务器部署。将自动尝试检测/创建外部网络 '${NETWORK_NAME}'...${RESET}"
        docker network inspect "$NETWORK_NAME" &>/dev/null || docker network create "$NETWORK_NAME"
        network_config="external: true"
    else
        echo -e "${GREEN} -> 已选择跨服务器部署。将自动在本地建立独立的网桥网络。${RESET}"
        network_config="driver: bridge"
    fi

    # 配置环境变量
    echo -ne "${YELLOW}请输入 Remnawave 面板 URL (如 https://remnawave.example.com 或 http://remnawave:3000): ${RESET}"
    read -r panel_url
    while [[ -z "$panel_url" ]]; do
        echo -e "${RED}错误: 面板 URL 不能为空！${RESET}"
        echo -ne "${YELLOW}请重新输入 Remnawave 面板 URL: ${RESET}"
        read -r panel_url
    done

    echo -ne "${YELLOW}请输入订阅页面本地访问端口 [默认: 3010]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3010"

    echo -ne "${YELLOW}请输入页面标题 (META_TITLE) [默认: Subscription Page]: ${RESET}"
    read -r meta_title
    [[ -z "$meta_title" ]] && meta_title="Subscription Page"

    echo -ne "${YELLOW}请输入页面描述 (META_DESCRIPTION) [默认: Nodes Subscription]: ${RESET}"
    read -r meta_desc
    [[ -z "$meta_desc" ]] && meta_desc="Nodes Subscription"

    # 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在动态生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=${panel_url}
      - APP_PORT=3010
      - META_TITLE=${meta_title}
      - META_DESCRIPTION=${meta_desc}
    ports:
      - '${custom_port}:3010'
    networks:
      - ${NETWORK_NAME}

networks:
  ${NETWORK_NAME}:
    ${network_config}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     订阅页面程序部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}订阅页访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后端面板链接   : ${panel_url}${RESET}"
    echo -e "${YELLOW}提示: 如果你绑定的是 127.0.0.1，可能需要反向代理(如 Nginx)才能公网访问。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_remnawave_sub() {
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
uninstall_remnawave_sub() {
    echo -ne "${YELLOW}确定要卸载并删除订阅页容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置文件目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}管理目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 容器开关控制
check_compose_exist() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

start_remnawave_sub() { check_compose_exist && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_remnawave_sub() { check_compose_exist && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_remnawave_sub() { check_compose_exist && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }

logs_remnawave_sub() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 容器未创建，无法查看日志！${RESET}"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}网页访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈Remnawave  Subscription Panel◈ ${RESET}"
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
        1) install_remnawave_sub ;;
        2) update_remnawave_sub ;;
        3) uninstall_remnawave_sub ;;
        4) start_remnawave_sub ;;
        5) stop_remnawave_sub ;;
        6) restart_remnawave_sub ;;
        7) logs_remnawave_sub ;;
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
