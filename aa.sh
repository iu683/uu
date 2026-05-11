#!/bin/bash
# ========================================
# TGuard 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tguard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.toml"

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

check_port() {

    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== TGuard 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
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
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi


    read -p "请输入 Telegram Bot Token: " BOT_TOKEN

    read -p "请输入管理员 TG ID: " ADMIN_ID

    read -p "请输入域名 [例如:https://tg.example.com]: " BASE_URL

    read -p "请输入 Turnstile Site Key: " TURNSTILE_SITE_KEY

    read -p "请输入 Turnstile Secret Key: " TURNSTILE_SECRET_KEY

    POSTGRES_PASSWORD=$(openssl rand -hex 12)
    API_KEY=$(openssl rand -hex 16)

    cat > "$CONFIG_FILE" <<EOF
[bot]
token = "$BOT_TOKEN"
verification_timeout = 300
verification_button_text = "🔐 开始验证"
admin_ids = [$ADMIN_ID]

[database]
host = "postgres"
port = 5432
name = "tguard"
user = "postgres"
password = "$POSTGRES_PASSWORD"
min_size = 1
max_size = 10

[captcha]
provider = "turnstile"
expire_minutes = 10
timeout_seconds = 30

[captcha.turnstile]
site_key = "$TURNSTILE_SITE_KEY"
secret_key = "$TURNSTILE_SECRET_KEY"

[api]
host = "0.0.0.0"
port = 8000
base_url = "$BASE_URL"
enable = true
api_key = "$API_KEY"
EOF

    cat > "$COMPOSE_FILE" <<EOF

services:
  postgres:
    image: postgres:16-alpine
    container_name: tguard-postgres
    environment:
      POSTGRES_DB: tguard
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
    volumes:
      - ./data:/var/lib/postgresql/data
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U postgres" ]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  bot:
    image: ghcr.io/sidecloudgroup/tguard:latest
    container_name: tguard-bot
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - PYTHONPATH=/app
    volumes:
      - ./config.toml:/app/config.toml
    command: python -m src.bot.main
    restart: unless-stopped
    healthcheck:
      test: [ "CMD-SHELL", "python -c \"import sys; sys.exit(0)\"" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  api:
    image: ghcr.io/sidecloudgroup/tguard:latest
    container_name: tguard-api
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "17985:8000"
    environment:
      - PYTHONPATH=/app
    volumes:
      - ./config.toml:/app/config.toml
    command: python -m src.api.main
    restart: unless-stopped
    healthcheck:
      test: [ "CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=5)\"" ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ TGuard 已启动${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${GREEN}🔑 API KEY: $API_KEY${RESET}"
    echo -e "${GREEN}🗄 PostgreSQL 密码: $POSTGRES_PASSWORD${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return

    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return

    docker compose logs -f
}

check_status() {

    docker ps | grep tguard

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ TGuard 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
