#!/bin/bash
# =================================================================
# LLBot & PMHQ 双服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 定义主容器和基本路径
PRIMARY_CONTAINER="llbot"
SECONDARY_CONTAINER="pmhq"
BASE_DIR="/opt/llbot"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取双容器状态、映射端口和数据目录
get_status_info() {
    local p_status s_status
    
    # 检查主容器状态
    if [ "$(docker ps -q -f name=^/${PRIMARY_CONTAINER}$)" ]; then p_status="run"; elif [ "$(docker ps -aq -f name=^/${PRIMARY_CONTAINER}$)" ]; then p_status="stop"; else p_status="none"; fi
    # 检查副容器状态
    if [ "$(docker ps -q -f name=^/${SECONDARY_CONTAINER}$)" ]; then s_status="run"; elif [ "$(docker ps -aq -f name=^/${SECONDARY_CONTAINER}$)" ]; then s_status="stop"; else s_status="none"; fi

    # 综合状态判断
    if [[ "$p_status" == "run" && "$s_status" == "run" ]]; then
        status="${YELLOW}运行中${RESET}"
    elif [[ "$p_status" == "none" && "$s_status" == "none" ]]; then
        status="${RED}未部署${RESET}"
    else
        status="${RED}异常/部分停止 (llbot:$p_status | pmhq:$s_status)${RESET}"
    fi

    # 如果主容器存在，提取端口和路径
    if [ "$(docker ps -aq -f name=^/${PRIMARY_CONTAINER}$)" ]; then
        # 提取主服务端口（默认 3001）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3001/tcp") 0).HostPort}}' "$PRIMARY_CONTAINER" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3001"

        # 提取数据挂载路径
        data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/llbot/data"}}{{.Source}}{{end}}{{end}}' "$PRIMARY_CONTAINER" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="$BASE_DIR/llbot_config"
    else
        webui_port="N/A"
        data_dir="N/A"
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

# 部署服务
install_services() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 LLBot WebUI 访问端口 [默认: 3001]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="3001"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 QQ 数据挂载绝对路径 [默认: $BASE_DIR/qq_data]: ${RESET}"
    read -r qq_data
    [[ -z "$qq_data" ]] && qq_data="$BASE_DIR/qq_data"

    echo -ne "${YELLOW}请输入 LLBot 配置挂载绝对路径 [默认: $BASE_DIR/llbot_config]: ${RESET}"
    read -r llbot_config
    [[ -z "$llbot_config" ]] && llbot_config="$BASE_DIR/llbot_config"

    # 1. 创建目录并赋权
    mkdir -p "$qq_data" "$llbot_config"
    chmod -R 777 "$BASE_DIR" "$qq_data" "$llbot_config"

    # 2. 动态生成符合要求的 docker-compose.yml
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"

services:
  pmhq:
    image: linyuchen/pmhq:latest
    container_name: pmhq
    privileged: true
    environment:
      - ENABLE_HEADLESS=false
    networks:
      - app_network
    volumes:
      - ${qq_data}:/root/.config/QQ
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:13000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  llbot:
    image: linyuchen/llbot:latest
    container_name: ${PRIMARY_CONTAINER}
    ports:
      - "${custom_port}:3001"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - PMHQ_HOST=pmhq
      - WEBUI_PORT=3001
    networks:
      - app_network
    volumes:
      - ${qq_data}:/root/.config/QQ
      - ${llbot_config}:/app/llbot/data
    depends_on:
      - pmhq
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "sh", "-c", "ps | grep '[n]ode'"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  app_network:
    driver: bridge
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动双端服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}由于包含健康检查，正在等待容器完全初始化 (约5秒)...${RESET}"
    sleep 5

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    LLBot & PMHQ 部署指令下发！ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}LLBot 配置路径 : $llbot_config${RESET}"
    echo -e "${YELLOW}QQ 数据路径    : $qq_data${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_services() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新服务镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_services() {
    echo -ne "${YELLOW}确定要卸载并删除所有相关容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和挂载的数据目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$PRIMARY_CONTAINER" "$SECONDARY_CONTAINER" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

check_compose_exist() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return 1
    fi
    return 0
}

start_services() { check_compose_exist && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}所有服务已启动${RESET}"; }
stop_services() { check_compose_exist && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}所有服务已停止${RESET}"; }
restart_services() { check_compose_exist && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}所有服务已重启${RESET}"; }

logs_services() { 
    echo -e "${CYAN}1. 查看 llbot 日志${RESET}"
    echo -e "${CYAN}2. 查看 pmhq 日志${RESET}"
    echo -ne "${GREEN}请选择要查看日志的容器 [默认 1]: ${RESET}"
    read -r log_choice
    if [[ "$log_choice" == "2" ]]; then
        docker logs -f "$SECONDARY_CONTAINER"
    else
        docker logs -f "$PRIMARY_CONTAINER"
    fi
}

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}WebUI 访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置挂载路径   : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  LLBot  管理面板  ◈    ${RESET}"
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
        1) install_services ;;
        2) update_services ;;
        3) uninstall_services ;;
        4) start_services ;;
        5) stop_services ;;
        6) restart_services ;;
        7) logs_services ;;
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
