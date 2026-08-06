#!/bin/bash
# =================================================================
# Pixtale Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="pixtale"
BASE_DIR="/opt/pixtale"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 格式化 URL 中的 IP (如果是 IPv6 则加上方括号 [])
format_ip_for_url() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

# 动态获取容器状态并联动健康检查
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        return 0
    fi
    
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        local health_status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$health_status" == "healthy" ]]; then
            status="${GREEN}运行中 (健康)${RESET}"
        elif [[ "$health_status" == "unhealthy" ]]; then
            status="${RED}运行中 (不健康)${RESET}"
        elif [[ "$health_status" == "starting" ]]; then
            status="${YELLOW}运行中 (启动中)${RESET}"
        else
            status="${GREEN}运行中${RESET}"
        fi
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8082/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8082"
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

# 部署 Pixtale 并初始化默认配置
install_pixtale() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$BASE_DIR/data"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入服务访问端口 (宿主机端口) [默认: 8082]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8082"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r custom_admin
    [[ -z "$custom_admin" ]] && custom_admin="admin"

    echo -ne "${YELLOW}请输入管理员密码 (留空则自动随机生成): ${RESET}"
    read -r custom_password
    if [[ -z "$custom_password" ]]; then
        custom_password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    fi

    # 生成随机的 JWT_SECRET
    local jwt_secret=$(openssl rand -hex 32)

    # 生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
PIX_PORT=$custom_port
PIX_ADMIN=$custom_admin
PIX_PASSWORD=$custom_password
JWT_SECRET=$jwt_secret
EOF

    # 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
    pixtale:
        image: aslost/pixtale:latest
        container_name: ${CONTAINER_NAME}
        restart: unless-stopped
        ports:
            - "\${PIX_PORT:-8082}:8082"
        volumes:
            - ./data:/app/data
        environment:
            - ADMIN=\${PIX_ADMIN:-admin}
            - PASSWORD=\${PIX_PASSWORD:-123456}
            - JWT_SECRET=\${JWT_SECRET:-abc}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Pixtale 服务...${RESET}"
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Pixtale 部署及启动成功！                 ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}登录用户名   : ${custom_admin}${RESET}"
    echo -e "${YELLOW}登录密码     : ${custom_password}${RESET}"
    echo -e "${YELLOW}JWT 密钥     : ${jwt_secret}${RESET}"
    echo -e "${YELLOW}配置文件路径 : $ENV_FILE${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_pixtale() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" pull
    docker compose --env-file "$ENV_FILE" up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_pixtale() {
    echo -ne "${YELLOW}确定要卸载并删除 Pixtale 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及数据目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_pixtale() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_pixtale() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_pixtale() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_pixtale() { 
    echo -e "${CYAN}--- Pixtale 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    
    # 尝试从 .env 中读取当前的账号及密钥展示
    local env_admin="N/A"
    local env_pass="N/A"
    local env_jwt="N/A"
    if [[ -f "$ENV_FILE" ]]; then
        env_admin=$(grep "^PIX_ADMIN=" "$ENV_FILE" | cut -d'=' -f2-)
        env_pass=$(grep "^PIX_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2-)
        env_jwt=$(grep "^JWT_SECRET=" "$ENV_FILE" | cut -d'=' -f2-)
    fi

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}登录用户名   : ${env_admin}${RESET}"
    echo -e "${YELLOW}登录密码     : ${env_pass}${RESET}"
    echo -e "${YELLOW}JWT 密钥     : ${env_jwt}${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   ◈  Pixtale 管理面板   ◈   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_pixtale ;;
        2) update_pixtale ;;
        3) uninstall_pixtale ;;
        4) start_pixtale ;;
        5) stop_pixtale ;;
        6) restart_pixtale ;;
        7) logs_pixtale ;;
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
