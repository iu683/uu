#!/bin/bash
# =================================================================
# Pocket-ID 轻量级身份验证中心 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="pocket-id"
BASE_DIR="/opt/pocket-id"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态和端口
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从容器或配置文件中提取映射端口
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="v2"

        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "1411/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="1411"
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

# 部署 Pocket-ID
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/data"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Pocket-ID 访问端口 (宿主机端口) [默认: 1411]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="1411"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    DETECT_IP=$(get_public_ip)
    echo -ne "${YELLOW}请输入您的服务域名或应用 URL [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r app_url
    [[ -z "$app_url" ]] && app_url="http://${DETECT_IP}:${custom_port}"

    # 1. 自动生成 32 位 Base64 加密密钥
    echo -e "${YELLOW}正在自动生成安全加密密钥 (ENCRYPTION_KEY)...${RESET}"
    if command -v openssl &> /dev/null; then
        auto_key=$(openssl rand -base64 32)
    else
        auto_key=$(date +%s | sha256sum | base64 | head -c 44)
    fi

    # 2. 动态生成 .env 环境变量文件
    echo -e "${YELLOW}正在生成环境变量文件 .env...${RESET}"
    cat <<EOF > "$ENV_FILE"
APP_URL=${app_url}
ENCRYPTION_KEY=${auto_key}
TRUST_PROXY=true
MAXMIND_LICENSE_KEY=
GEOLITE_DB_PATH=data/GeoLite2-City.mmdb
PUID=1000
PGID=1000
LOG_LEVEL=info
LOG_JSON=true
ANALYTICS_DISABLED=true
ALLOW_USER_SIGNUPS=open
EOF

    # 3. 动态生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  pocket-id:
    image: ghcr.io/pocket-id/pocket-id:v2
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    env_file: .env
    ports:
      - "${custom_port}:1411"
    volumes:
      - "./data:/app/data"
    healthcheck:
      test: [ "CMD", "/app/pocket-id", "healthcheck" ]
      interval: 1m30s
      timeout: 5s
      retries: 2
      start_period: 10s
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Pocket-ID...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并执行健康检查 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}      Pocket-ID 部署成功！      ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : ${app_url}${RESET}"
    echo -e "${YELLOW}环境配置路径   : $ENV_FILE${RESET}"
    echo -e "${YELLOW}Compose 路径   : $COMPOSE_FILE${RESET}"
    echo -e "${RED}安全建议       : 初始管理员注册完成后，建议修改 .env 中的${RESET}"
    echo -e "${RED}                 ALLOW_USER_SIGNUPS=disabled 并重启容器以防越权。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新 Pocket-ID 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取 Pocket-ID 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Pocket-ID
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 Pocket-ID 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地所有配置及身份数据库 (./data) ？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及数据库目录已彻底清理。${RESET}"
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
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}当前镜像       : ${img_version}${RESET}"
    if [[ -f "$ENV_FILE" ]]; then
        local current_url=$(grep -E '^APP_URL=' "$ENV_FILE" | cut -d'=' -f2-)
        echo -e "${YELLOW}应用配置 URL  : ${CYAN}${current_url}${RESET}"
    fi
    echo -e "${YELLOW}内部监听端口   : ${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Pocket-ID 管理面板  ◈    ${RESET}"
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
