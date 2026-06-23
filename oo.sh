#!/bin/bash
# =================================================================
# gemini-business2api 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="gemini-business2api"
BASE_DIR="/opt/gemini-business2api"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
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

# 动态获取容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "7860/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="7860"
    else
        webui_port="N/A"
    fi
}

# 部署服务
install_gemini() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 配置管理后台登录密码 ADMIN_KEY (回车默认纯随机)
    echo -ne "${YELLOW}请输入后台管理密码 ADMIN_KEY [直接回车自动生成随机密码]: ${RESET}"
    read -r custom_admin_key
    if [[ -z "$custom_admin_key" ]]; then
        custom_admin_key="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
        echo -e "${GREEN} -> 已自动生成后台密码: $custom_admin_key${RESET}"
    fi

    # 2. 宿主机映射主端口
    echo -ne "${YELLOW}请输入主服务访问端口 (PORT) [默认: 7860]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="7860"

    # 3. 宿主机映射 Worker 健康端口
    echo -ne "${YELLOW}请输入刷新 Worker 健康端口 (REFRESH_HEALTH_PORT) [默认: 8080]: ${RESET}"
    read -r custom_worker_port
    [[ -z "$custom_worker_port" ]] && custom_worker_port="8080"

    # 4. 数据存放基准路径
    echo -ne "${YELLOW}请输入数据存放绝对基准路径 [默认: /opt/gemini-business2api]: ${RESET}"
    read -r custom_path
    [[ -z "$custom_path" ]] && custom_path="/opt/gemini-business2api"

    # 定义子挂载目录
    local path_data="$custom_path/data"

    # 检查并清理残留的坏文件
    if [ -e "$path_data" ] && [ ! -d "$path_data" ]; then
        rm -rf "$path_data"
    fi
    mkdir -p "$path_data"
    chmod -R 777 "$custom_path" 2>/dev/null

    # 5. 是否同时启用 refresh-worker 刷新组件
    echo -ne "${YELLOW}是否同步启动定时刷新 Worker 组件 (refresh-worker)？(y/n) [默认: n]: ${RESET}"
    read -r enable_worker
    [[ -z "$enable_worker" ]] && enable_worker="n"

    # 组织并生成环境配置文件 .env
    echo -e "${YELLOW}正在生成配套的 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
ADMIN_KEY=${custom_admin_key}
PORT=${custom_port}
REFRESH_WORKER_IMAGE=cooooookk/gemini-refresh-worker:latest
REFRESH_HEALTH_PORT=${custom_worker_port}
EOF

    # 同步数据流路径
    if [ "$custom_path" != "$BASE_DIR" ]; then
        rm -rf "$BASE_DIR/data"
        ln -sf "$path_data" "$BASE_DIR/data"
    fi

    # 生成魔改后的 docker-compose.yml (彻底移除官方死锁的 healthcheck)
    echo -e "${YELLOW}正在生成完美适配自定义端口的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  gemini-api:
    image: cooooookk/gemini-business2api:latest
    container_name: gemini-business2api
    restart: unless-stopped
    ports:
      - "${custom_port}:7860"
    env_file:
      - .env
    volumes:
      - ./data:/app/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  refresh-worker:
    image: \${REFRESH_WORKER_IMAGE:-cooooookk/gemini-refresh-worker:latest}
    container_name: gemini-refresh-worker
    restart: unless-stopped
    profiles:
      - refresh
    depends_on:
      - gemini-api
    env_file:
      - .env
    environment:
      SQLITE_PATH: /app/data/data.db
      HEALTH_PORT: ${custom_worker_port}
    volumes:
      - ./data:/app/data
    ports:
      - "${custom_worker_port}:${custom_worker_port}"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    echo -e "${YELLOW}正在彻底清理旧集群并重新秒级拉起服务...${RESET}"
    cd "$BASE_DIR"
    docker compose --profile refresh down --remove-orphans 2>/dev/null
    
    if [[ "$enable_worker" == "y" || "$enable_worker" == "Y" ]]; then
        docker compose --profile refresh up -d --force-recreate
    else
        docker compose up -d --force-recreate
    fi

    echo -e "${YELLOW}等待服务初始化 (约5秒)...${RESET}"
    sleep 5

    local current_ip
    current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    gemini-business2api 部署成功！${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}后台管理地址   : http://${current_ip}:${custom_port}/admin${RESET}"
    echo -e "${YELLOW}管理登录密码   : ${custom_admin_key}${RESET}"
    echo -e "${YELLOW}数据本地存放路径 : $path_data${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${CYAN}💡 组件开启状态：${RESET}"
    echo -e "${YELLOW}定时刷新 Worker组件 : $([ "$enable_worker" = "y" ] && echo -e "${GREEN}已开启 (本地映射端口: $custom_worker_port)${RESET}" || echo -e "${RED}未开启${RESET}")${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_gemini() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新服务镜像...${RESET}"
    cd "$BASE_DIR" && docker compose --profile refresh pull
    if [ "$(docker ps -aq -f name=^/gemini-refresh-worker$)" ]; then
        docker compose --profile refresh up -d --remove-orphans
    else
        docker compose up -d --remove-orphans
    fi
    echo -e "${GREEN}集群更新完成！组件均已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_gemini() {
    echo -ne "${YELLOW}确定要卸载并删除 gemini-business2api 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose --profile refresh down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地存储的所有数据库和凭证数据？(y/n): ${RESET}"
            read -r clean_data
            if [[ "$clean_data" == "y" || "$clean_data" == "Y" ]]; then
                rm -rf "$BASE_DIR"
                if [ -d "/opt/gemini-business2api/data" ]; then
                    rm -rf "/opt/gemini-business2api/data"
                fi
                echo -e "${GREEN}数据资产和配置文件已彻底清理。${RESET}"
            fi
        else
            docker rm -f gemini-business2api gemini-refresh-worker 2>/dev/null
            echo -e "${GREEN}独立容器已强行清除。${RESET}"
        fi
        echo -e "${GREEN}卸载彻底完成！${RESET}"
    fi
}

start_gemini() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose --profile refresh start && echo -e "${GREEN}服务集群已全部拉起启动${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法启动。${RESET}"
    fi
}

stop_gemini() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose --profile refresh stop && echo -e "${YELLOW}服务集群已全面停止挂起${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法停止。${RESET}"
    fi
}

restart_gemini() { 
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$BASE_DIR" && docker compose --profile refresh restart && echo -e "${GREEN}服务集群已成功完成重启${RESET}"
    else
        echo -e "${RED}错误: 未检测到配置，无法重启。${RESET}"
    fi
}

logs_gemini() { 
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        docker logs -f "$CONTAINER_NAME"
    else
        echo -e "${RED}错误: 主容器不存在，无法追踪日志。${RESET}"
    fi
}

show_info() {
    get_status_info
    local current_ip
    current_ip=$(get_public_ip)
    
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}主服务状态     : $status"
    if [[ "$webui_port" == "N/A" ]]; then
        echo -e "${YELLOW}后台管理地址   : N/A${RESET}"
    else
        echo -e "${YELLOW}后台管理地址   : http://${current_ip}:${webui_port}/admin${RESET}"
    fi
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}管理登录密码   : ${custom_admin_key}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈ gemini-business2api 管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}主服务状态 :${RESET} $status"
    echo -e "${GREEN}主访问端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_gemini ;;
        2) update_gemini ;;
        3) uninstall_gemini ;;
        4) start_gemini ;;
        5) stop_gemini ;;
        6) restart_gemini ;;
        7) logs_gemini ;;
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
