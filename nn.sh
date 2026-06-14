#!/bin/bash
# ========================================
# Komari Traffic Hub 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="komari-hub"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Komari Traffic Hub 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新服务${RESET}"
        echo -e "${GREEN}3) 重启服务${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装配置？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 交互式收集配置
    echo -e "${YELLOW}--- 请输入基础配置信息 ---${RESET}"
    
    read -p "请输入 Komari 面板地址 (例: https://komari.example): " komari_url
    KOMARI_BASE_URL=${komari_url:-"https://your-komari.example"}

    read -p "请输入 Telegram Bot Token: " tg_token
    TELEGRAM_BOT_TOKEN=${tg_token:-"123456:YOUR_BOT_TOKEN"}

    read -p "请输入 Telegram Chat ID: " tg_chat_id
    TELEGRAM_CHAT_ID=${tg_chat_id:-"123456789"}

    read -p "请输入 Web 面板访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "请输入 Web 面板管理员密码 (必填): " web_pass
    while [ -z "$web_pass" ]; do
        read -p "${RED}密码不能为空，请重新输入:${RESET} " web_pass
    done

    # 自动生成随机 Session 密钥
    WEB_SESSION_SECRET=$(openssl rand -hex 16)

    # 1. 写入 .env 配置文件
    cat > "$ENV_FILE" <<EOF
# Komari 面板地址（不要以 / 结尾）
KOMARI_BASE_URL=${KOMARI_BASE_URL}

# Komari API 超时（秒）
KOMARI_TIMEOUT_SECONDS=15

# Komari API 鉴权（可选）
KOMARI_API_TOKEN=
KOMARI_API_TOKEN_HEADER=Authorization
KOMARI_API_TOKEN_PREFIX=Bearer

# Komari 节点并发请求数
KOMARI_FETCH_WORKERS=6

# Telegram
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}

# 允许接收命令的 chat（可选，逗号分隔）
TELEGRAM_ALLOWED_CHAT_IDS=

# 管理员 chat（可选，逗号分隔）
TELEGRAM_ADMIN_CHAT_IDS=

# AI（可选，启用 /ask 与 /ai）
AI_API_BASE=
AI_API_KEY=
AI_MODEL=

# AI 数据包缓存时长（秒），默认 3600；设为 0 关闭缓存
AI_PACK_CACHE_TTL_SECONDS=3600

# Web 面板
WEB_USERNAME=admin
WEB_PASSWORD=${web_pass}
WEB_SESSION_SECRET=${WEB_SESSION_SECRET}
WEB_PORT=${PORT}

# 启动通知
BOT_START_NOTIFY=1
BOT_INSTANCE_NAME=Komari-Hub-Server

# 容器内数据目录（固定）
DATA_DIR=/data

# 统计时区（默认 Asia/Shanghai）
STAT_TZ=Asia/Shanghai

# Top 榜数量
TOP_N=3

# 连续快照设置
SAMPLE_INTERVAL_SECONDS=300
SAMPLE_RETENTION_HOURS=2
TRAFFIC_SNAPSHOT_RETENTION_DAYS=45

# 历史数据策略
HISTORY_HOT_DAYS=60
HISTORY_RETENTION_DAYS=400
TASK_RUN_RETENTION_DAYS=90
NODE_DAILY_USAGE_RETENTION_DAYS=365

# 智能告警
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

# 日志
LOG_LEVEL=INFO
LOG_FILE=
EOF

    # 2. 写入 docker-compose.yml 配置文件
    cat > "$COMPOSE_FILE" <<EOF
services:
  bot:
    image: ghcr.io/wirelouis/komari-traffic-hub:latest
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
    env_file: .env
    environment:
      - TZ=Asia/Shanghai
      - STAT_TZ=Asia/Shanghai
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:\${WEB_PORT:-8080}:8080"
    restart: unless-stopped
    command: ["uvicorn", "web_app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

    # 启动服务
    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Komari Traffic Hub 部署成功！${RESET}"
    echo -e "${YELLOW}🌐 Web 面板访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据挂载目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📄 完整配置文件: $ENV_FILE (如需微调高级告警参数可稍后自行编辑此文件)${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在拉取最新镜像...${RESET}"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 服务已更新并重启${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 所有服务已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    echo
    read -p "按回车返回菜单..."
}

uninstall_app() {
   
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 卸载完成！${RESET}"
    read -p "按回车返回菜单..."
}

# 运行菜单
menu
