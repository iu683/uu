#!/bin/bash
# ========================================
# Renewlet 一键管理脚本
# 官方 .env + compose 完整版
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="renewlet"
APP_DIR="/opt/$APP_NAME"

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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
        echo -e "${GREEN}========Renewlet 管理菜单========${RESET}"
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

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    read -p "请输入站点 URL [例如:https://renewlet.example.com]: " input_url
    APP_URL=${input_url:-http://127.0.0.1:${PORT}}

    TZ_VALUE=${input_tz:-Asia/Shanghai}

    RENEWLET_IMAGE=${input_image:-zhiyingzzhou/renewlet:latest}

    PB_ENCRYPTION_KEY=$(openssl rand -hex 16)
    CRON_SECRET=$(openssl rand -hex 16)

    cat > "$ENV_FILE" <<EOF
# ------------------------------------------------------------
# Renewlet Docker 配置
# ------------------------------------------------------------

PORT="${PORT}"

RENEWLET_IMAGE="${RENEWLET_IMAGE}"

GOMEMLIMIT="128MiB"
MEM_LIMIT="256m"

TZ="${TZ_VALUE}"

APP_URL="${APP_URL}"

PB_ENCRYPTION_KEY="${PB_ENCRYPTION_KEY}"

CRON_SECRET="${CRON_SECRET}"

# SMTP 配置（可选）
# SMTP_HOST="smtp.example.com"
# SMTP_PORT="587"
# SMTP_USER="smtp-user"
# SMTP_PASSWORD="smtp-password"
# SMTP_FROM="Renewlet <noreply@example.com>"
# SMTP_TLS="false"

# 自动备份（可选）
# BACKUPS_CRON="0 3 * * *"
# BACKUPS_CRON_MAX_KEEP="7"

NOTIFICATION_SCHEDULER_ENABLED="true"
NOTIFICATION_SCHEDULER_CRON="* * * * *"

NOTIFICATION_CRON_WINDOW_MINUTES="2"

NOTIFICATION_MAX_RETRIES="3"

NOTIFICATION_STALE_SENDING_MINUTES="15"
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  web:
    image: \${RENEWLET_IMAGE:-zhiyingzzhou/renewlet:latest}
    container_name: renewlet

    environment:
      GOMEMLIMIT: \${GOMEMLIMIT:-128MiB}

      TZ: \${TZ:-Asia/Shanghai}

      APP_URL: \${APP_URL:-http://localhost:3000}

      PB_ENCRYPTION_KEY: \${PB_ENCRYPTION_KEY:-}

      SMTP_HOST: \${SMTP_HOST:-}
      SMTP_PORT: \${SMTP_PORT:-587}
      SMTP_USER: \${SMTP_USER:-}
      SMTP_PASSWORD: \${SMTP_PASSWORD:-}
      SMTP_FROM: \${SMTP_FROM:-}
      SMTP_TLS: \${SMTP_TLS:-false}

      BACKUPS_CRON: \${BACKUPS_CRON:-}
      BACKUPS_CRON_MAX_KEEP: \${BACKUPS_CRON_MAX_KEEP:-3}

      NOTIFICATION_SCHEDULER_ENABLED: \${NOTIFICATION_SCHEDULER_ENABLED:-true}

      CRON_SECRET: \${CRON_SECRET:-}

      NOTIFICATION_SCHEDULER_CRON: "\${NOTIFICATION_SCHEDULER_CRON:-* * * * *}"

      NOTIFICATION_CRON_WINDOW_MINUTES: \${NOTIFICATION_CRON_WINDOW_MINUTES:-2}

      NOTIFICATION_MAX_RETRIES: \${NOTIFICATION_MAX_RETRIES:-3}

      NOTIFICATION_STALE_SENDING_MINUTES: \${NOTIFICATION_STALE_SENDING_MINUTES:-15}

    volumes:
      - ./data:/pb_data

    ports:
      - "127.0.0.1:${PORT}:3000"

    healthcheck:
      test: ["CMD", "/renewlet", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    mem_limit: \${MEM_LIMIT:-256m}

    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}✅ Renewlet 安装完成${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 访问地址: ${APP_URL}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🔑 PB_ENCRYPTION_KEY:${RESET}"
    echo "${PB_ENCRYPTION_KEY}"
    echo -e "${GREEN}🔑 CRON_SECRET:${RESET}"
    echo "${CRON_SECRET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Renewlet 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart renewlet

    echo -e "${GREEN}✅ Renewlet 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f renewlet
}

check_status() {

    docker ps --filter "name=renewlet"

    read -p "按回车返回菜单..."
}

uninstall_app() {


    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Renewlet 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
