#!/bin/bash
# =================================================================
# tg4opencodego Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="tg4opencodego"
BASE_DIR="/opt/tg4opencodego"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        port_display="N/A (无端口)"
        return 0
    fi
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
        port_display="无端口 (Telegram 机器人)"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":" ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":" ]] && echo "$ip" && return 0
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

# 部署 tg4opencodego
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/tg4opencodego-data"
    chmod 777 "$BASE_DIR/tg4opencodego-data"

    echo -e "${CYAN}====== 1. 机器人与 API 配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Telegram Bot Token (必填): ${RESET}"
    read -r tg_token
    while [[ -z "$tg_token" ]]; do
        echo -e "${RED}错误: Telegram Bot Token 不能为空！${RESET}"
        echo -ne "${YELLOW}请输入 Telegram Bot Token: ${RESET}"
        read -r tg_token
    done

    echo -ne "${YELLOW}请输入 OpenCode API Key (sk-...) [必填]: ${RESET}"
    read -r opencode_key
    while [[ -z "$opencode_key" ]]; do
        echo -e "${RED}错误: OpenCode API Key 不能为空！${RESET}"
        echo -ne "${YELLOW}请输入 OpenCode API Key: ${RESET}"
        read -r opencode_key
    done

    echo -ne "${YELLOW}请输入允许使用的 Telegram User IDs (可选，逗号分隔): ${RESET}"
    read -r allowed_ids

    # 生成 .env 文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat <<EOF > "$ENV_FILE"
TELEGRAM_BOT_TOKEN=${tg_token}
ALLOWED_USER_IDS=${allowed_ids}
OPENCODE_API_KEY=${opencode_key}
OPENCODE_BASE_URL=https://opencode.ai
OPENCODE_USAGE_PATH=/inference/go/v1/usage
DEFAULT_TZ=Asia/Shanghai
DEFAULT_PUSH_TIMES=09:00
CHECK_INTERVAL_MIN=15
ALERT_THRESHOLDS=50,80,95,100
SQLITE_PATH=./data/tg4opencodego.db
LOG_LEVEL=info
EOF
    chmod 600 "$ENV_FILE"

    # 生成 docker-compose.yml 文件
    echo -e "${YELLOW}正在生成规范的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  tg4opencodego:
    image: ghcr.io/vps4128/tg4opencodego:latest
    container_name: ${CONTAINER_NAME}
    env_file: .env
    restart: unless-stopped
    init: true
    volumes:
      - ./tg4opencodego-data:/app/data
    healthcheck:
      test: ["CMD", "node", "dist/healthcheck.js"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s

volumes:
  tg4opencodego-data:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 tg4opencodego...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   tg4opencodego 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}数据目录     : ${BASE_DIR}/tg4opencodego-data${RESET}"
    echo -e "${YELLOW}配置文件路径 : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载服务 (带分步清理确认)
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 tg4opencodego 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地数据目录及整个项目文件夹 (${BASE_DIR})？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}项目及本地数据目录已彻底清理。${RESET}"
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
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}运行模式       : Telegram Bot (无对外端口)${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈ tg4opencodego 管理面板 ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
