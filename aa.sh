#!/bin/bash
# =================================================================
# PocketDrive Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="pocketdrive"
ARIA2_CONTAINER_NAME="pocketdrive-aria2"
BASE_DIR="/opt/pocketdrive"
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

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "16688/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="16688"
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

# 部署 PocketDrive 并初始化默认配置
install_pocketdrive() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$BASE_DIR/data"
    mkdir -p "$BASE_DIR/config/aria2"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 PocketDrive 服务访问端口 (宿主机端口) [默认: 16688]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="16688"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 Aria2 RPC 密钥 (留空则自动随机生成): ${RESET}"
    read -r custom_aria2_secret
    if [[ -z "$custom_aria2_secret" ]]; then
        custom_aria2_secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)
    fi

    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r custom_admin_user
    [[ -z "$custom_admin_user" ]] && custom_admin_user="admin"

    echo -ne "${YELLOW}请输入管理员密码 (留空则自动随机生成): ${RESET}"
    read -r custom_admin_password
    if [[ -z "$custom_admin_password" ]]; then
        custom_admin_password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
    fi

    # 生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
ARIA2_SECRET=$custom_aria2_secret
POCKETDRIVE_ADMIN_USER=$custom_admin_user
POCKETDRIVE_ADMIN_PASSWORD=$custom_admin_password
EOF

    # 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
    pocketdrive:
        image: ghcr.io/lqlcj/pocketdrive:latest
        container_name: ${CONTAINER_NAME}
        restart: unless-stopped
        init: true
        ports:
            - '${custom_port}:16688'
        environment:
            - POCKETDRIVE_DATA_DIR=/data
            - POCKETDRIVE_DB=/config/pocketdrive.db
            - POCKETDRIVE_ADMIN_USER=\${POCKETDRIVE_ADMIN_USER:-admin}
            - POCKETDRIVE_ADMIN_PASSWORD=\${POCKETDRIVE_ADMIN_PASSWORD:-}
            - POCKETDRIVE_ARIA2_RPC=http://aria2:6800/jsonrpc
            - POCKETDRIVE_ARIA2_SECRET=\${ARIA2_SECRET:?请设置随机的 ARIA2_SECRET}
            - POCKETDRIVE_ARIA2_DATA_DIR=/data
        volumes:
            - ./data:/data
            - ./config:/config
        depends_on:
            - aria2
    aria2:
        image: p3terx/aria2-pro
        container_name: ${ARIA2_CONTAINER_NAME}
        restart: unless-stopped
        environment:
            - RPC_SECRET=\${ARIA2_SECRET:?请设置随机的 ARIA2_SECRET}
            - LISTEN_PORT=6888
            - MAX_CONCURRENT_DOWNLOADS=3
            - PUID=0
            - PGID=0
            - UMASK_SET=022
        volumes:
            - ./data:/data
            - ./config/aria2:/config
        ports:
            - '6888:6888'
            - '6888:6888/udp'
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 PocketDrive 及 Aria2 服务...${RESET}"
    cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          PocketDrive 部署及启动成功！              ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}登录用户名   : ${custom_admin_user}${RESET}"
    echo -e "${YELLOW}登录密码     : ${custom_admin_password}${RESET}"
    echo -e "${YELLOW}Aria2 密钥   : ${custom_aria2_secret}${RESET}"
    echo -e "${YELLOW}配置文件路径 : $ENV_FILE${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_pocketdrive() {
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
uninstall_pocketdrive() {
    echo -ne "${YELLOW}确定要卸载并删除 PocketDrive 及 Aria2 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及下载挂载数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" "$ARIA2_CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_pocketdrive() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_pocketdrive() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_pocketdrive() { cd "$BASE_DIR" && docker compose --env-file "$ENV_FILE" restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_pocketdrive() { 
    echo -e "${CYAN}--- PocketDrive 容器当前运行日志 (按 Ctrl+C 退出查看) ---${RESET}"
    docker logs -f "$CONTAINER_NAME"; 
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    
    # 尝试从 .env 中读取当前的用户名、密码和密钥展示
    local env_user="N/A"
    local env_pass="N/A"
    local env_secret="N/A"
    if [[ -f "$ENV_FILE" ]]; then
        env_user=$(grep "^POCKETDRIVE_ADMIN_USER=" "$ENV_FILE" | cut -d'=' -f2-)
        env_pass=$(grep "^POCKETDRIVE_ADMIN_PASSWORD=" "$ENV_FILE" | cut -d'=' -f2-)
        env_secret=$(grep "^ARIA2_SECRET=" "$ENV_FILE" | cut -d'=' -f2-)
    fi

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}镜像名称     : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}登录用户名   : ${env_user}${RESET}"
    echo -e "${YELLOW}登录密码     : ${env_pass}${RESET}"
    echo -e "${YELLOW}Aria2 密钥   : ${env_secret}${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${ENV_FILE}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}  ◈  PocketDrive 管理面板  ◈   ${RESET}"
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
        1) install_pocketdrive ;;
        2) update_pocketdrive ;;
        3) uninstall_pocketdrive ;;
        4) start_pocketdrive ;;
        5) stop_pocketdrive ;;
        6) restart_pocketdrive ;;
        7) logs_pocketdrive ;;
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
