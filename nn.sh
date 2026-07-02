#!/bin/bash
# =================================================================
# Komari Traffic Hub Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/komari-traffic"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
DATA_DIR="$BASE_DIR/data"

# 双容器名称定义
CONTAINER_BOT="komari-traffic-bot"
CONTAINER_WEB="komari-traffic-web"

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

# 动态获取双容器状态、映射端口和环境变量配置
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        webui_port="N/A"
        return 0
    fi

    # 1. 检查两个容器的状态
    local bot_run=$(docker ps -q -f name=^/${CONTAINER_BOT}$)
    local web_run=$(docker ps -q -f name=^/${CONTAINER_WEB}$)
    local bot_exist=$(docker ps -aq -f name=^/${CONTAINER_BOT}$)
    local web_exist=$(docker ps -aq -f name=^/${CONTAINER_WEB}$)

    if [[ -n "$bot_run" && -n "$web_run" ]]; then
        status="${GREEN}运行中 (双服务正常)${RESET}"
    elif [[ -n "$bot_run" || -n "$web_run" ]]; then
        status="${YELLOW}部分运行 (请检查日志)${RESET}"
    elif [[ -n "$bot_exist" || -n "$web_exist" ]]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 从环境或容器提取 Web 端口
    if [[ -f "$ENV_FILE" ]]; then
        webui_port=$(grep -E "^WEB_PORT=" "$ENV_FILE" | cut -d'=' -f2)
    fi
    [[ -z "$webui_port" ]] && webui_port="8080"
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

# 部署 Komari Traffic Hub
install_hub() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    mkdir -p "$DATA_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}1. 请输入 Komari 后端基础 URL (例如 https://komari.example.com): ${RESET}"
    read -r komari_url
    [[ -z "$komari_url" ]] && komari_url="https://your-komari.example"

    echo -ne "${YELLOW}2. 请输入 Telegram Bot Token: ${RESET}"
    read -r tg_token
    
    echo -ne "${YELLOW}3. 请输入 Telegram 主接收 Chat ID: ${RESET}"
    read -r tg_chat_id

    echo -ne "${YELLOW}4. 请输入网页登录密码 (WEB_PASSWORD): ${RESET}"
    read -r web_password
    [[ -z "$web_password" ]] && web_password="SecurePassword123"

    echo -ne "${YELLOW}5. 请输入服务访问端口 (宿主机端口) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 修改目录权限（容器内部为非 root 用户 10001 运行）
    echo -e "${YELLOW}正在配置本地数据目录权限(UID 10001)...${RESET}"
    sudo chown -R 10001:10001 "$DATA_DIR"
    sudo chmod -R u+rwX,go+rX "$DATA_DIR"

    # 生成符合要求的 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
KOMARI_BASE_URL=${komari_url}
TELEGRAM_BOT_TOKEN=${tg_token}
TELEGRAM_CHAT_ID=${tg_chat_id}
TELEGRAM_ALLOWED_CHAT_IDS=
TELEGRAM_ADMIN_CHAT_IDS=
AI_API_BASE=
AI_API_KEY=
AI_MODEL=
AI_PACK_CACHE_TTL_SECONDS=3600
WEB_USERNAME=admin
WEB_PASSWORD=${web_password}
WEB_SESSION_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
WEB_PORT=${custom_port}
BOT_START_NOTIFY=1
BOT_INSTANCE_NAME=Komari-Traffic-Hub
KOMARI_TIMEOUT_SECONDS=15
KOMARI_API_TOKEN=
KOMARI_API_TOKEN_HEADER=Authorization
KOMARI_API_TOKEN_PREFIX=Bearer
KOMARI_FETCH_WORKERS=6
DATA_DIR=/data
STAT_TZ=Asia/Shanghai
TOP_N=3
SAMPLE_INTERVAL_SECONDS=300
SAMPLE_RETENTION_HOURS=2
TRAFFIC_SNAPSHOT_RETENTION_DAYS=45
HISTORY_HOT_DAYS=60
HISTORY_RETENTION_DAYS=365
TASK_RUN_RETENTION_DAYS=7
NODE_DAILY_USAGE_RETENTION_DAYS=365
ALERTS_ENABLED=1
TELEGRAM_ALERT_CHAT_ID=
ALERT_COOLDOWN_SECONDS=1800
ALERT_SILENCE_WINDOWS=
ALERT_NODE_MISSING_SAMPLES=2
ALERT_WINDOW_MINUTES=60
ALERT_TOTAL_WINDOW_BYTES=
ALERT_NODE_WINDOW_BYTES=
ALERT_DAILY_TOTAL_BYTES=
ALERT_DAILY_NODE_BYTES=
ALERT_RECOVERY_NOTIFY=1
LOG_LEVEL=INFO
LOG_FILE=
EOF

    # 生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  bot:
    image: ghcr.io/wirelouis/komari-traffic-hub:latest
    container_name: ${CONTAINER_BOT}
    env_file: .env
    environment:
      - TZ=Asia/Shanghai
      - STAT_TZ=Asia/Shanghai
    volumes:
      - ./data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "/app/komari_traffic_report.py", "health"]
      interval: 30s
      timeout: 10s
      retries: 3
    command: ["python", "/app/komari_traffic_report.py", "listen"]

  web:
    image: ghcr.io/wirelouis/komari-traffic-hub:latest
    container_name: ${CONTAINER_WEB}
    env_file: .env
    environment:
      - TZ=Asia/Shanghai
      - STAT_TZ=Asia/Shanghai
    volumes:
      - ./data:/data
    ports:
      - "\${WEB_PORT:-8080}:8080"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/api/health', timeout=5)"]
      interval: 30s
      timeout: 10s
      retries: 3
    command: ["uvicorn", "web_app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        Komari Traffic Hub 部署及初始化成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 面板地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}网页登录用户 : admin${RESET}"
    echo -e "${YELLOW}网页登录密码 : ${web_password}${RESET}"
    echo -e "${YELLOW}数据挂载路径 : $DATA_DIR${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}提示: 更多高级告警及AI配置参数可随时选择选项 8 重新编辑 .env 文件。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新镜像
update_hub() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新镜像并平滑重启服务...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_hub() {
    echo -ne "${YELLOW}确定要卸载并删除 Komari Traffic Hub 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有本地配置文件及历史数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及本地数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_BOT" "$CONTAINER_WEB" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_hub() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}双容器服务已启动${RESET}"; }
stop_hub() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}双容器服务已停止${RESET}"; }
restart_hub() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}双容器服务已重启${RESET}"; }

logs_hub() { 
    echo -e "${CYAN}--- 容器当前聚合运行日志 (按 Ctrl+C 退出) ---${RESET}"
    cd "$BASE_DIR" && docker compose logs -f --tail=100
}

# 新增编辑配置功能
edit_config() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在打开配置文件，修改完毕后保存退出，系统将自动使配置生效...${RESET}"
    sleep 1
    nano "$ENV_FILE"
    echo -e "${YELLOW}正在应用新配置重启容器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --remove-orphans
    echo -e "${GREEN}配置已成功热重载生效！${RESET}"
}

show_info() {
    get_status_info
    RAW_IP=$(get_public_ip)
    DETECT_IP=$(format_ip_for_url "$RAW_IP")
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}当前状态     : $status"
    echo -e "${YELLOW}Web面板地址  : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}网页登录密码 : ${web_password}${RESET}"
    echo -e "${YELLOW}数据挂载路径 : ${DATA_DIR}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} ◈ Komari Traffic Hub 面板 ◈ ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 修改配置${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_hub ;;
        2) update_hub ;;
        3) uninstall_hub ;;
        4) start_hub ;;
        5) stop_hub ;;
        6) restart_hub ;;
        7) logs_hub ;;
        8) edit_config ;;
        9) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
