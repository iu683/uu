#!/bin/bash
# ========================================
# RuleFlow 一键管理脚本(内置PG+Redis)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ruleflow"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

generate_secret() {
    openssl rand -hex 24
}

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

        echo -e "${GREEN}=== RuleFlow 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "PostgreSQL数据库名 [默认:ruleflow]: " input_db
    POSTGRES_DB=${input_db:-ruleflow}

    read -p "PostgreSQL用户名 [默认:ruleflow]: " input_user
    POSTGRES_USER=${input_user:-ruleflow}

    POSTGRES_PASSWORD=$(generate_secret)
    REDIS_PASSWORD=$(generate_secret)

    read -p "CACHE_TTL_SECONDS [默认:3600]: " input_cache
    CACHE_TTL_SECONDS=${input_cache:-3600}

    read -p "LOG_KEEP_DAYS [默认:30]: " input_days
    LOG_KEEP_DAYS=${input_days:-30}

    read -p "LOG_MAX_RECORDS [默认:10000]: " input_logs
    LOG_MAX_RECORDS=${input_logs:-10000}

    read -p "SURGE_MANAGED_CONFIG_BASE_URL [可留空]: " SURGE_URL

    cat > "$ENV_FILE" <<EOF
PORT=${PORT}

POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

REDIS_PASSWORD=${REDIS_PASSWORD}

CACHE_TTL_SECONDS=${CACHE_TTL_SECONDS}
LOG_KEEP_DAYS=${LOG_KEEP_DAYS}
LOG_MAX_RECORDS=${LOG_MAX_RECORDS}
SURGE_MANAGED_CONFIG_BASE_URL=${SURGE_URL}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  ruleflow:
    image: ghcr.io/0xunixio/ruleflow:latest

    container_name: ruleflow

    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:8080"

    environment:
      PORT: "8080"
      DATABASE_URL: postgresql://\${POSTGRES_USER:-ruleflow}:\${POSTGRES_PASSWORD}@postgres:5432/\${POSTGRES_DB:-ruleflow}?sslmode=disable
      REDIS_ADDR: redis:6379
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      CACHE_TTL_SECONDS: \${CACHE_TTL_SECONDS:-3600}
      LOG_KEEP_DAYS: \${LOG_KEEP_DAYS:-30}
      LOG_MAX_RECORDS: \${LOG_MAX_RECORDS:-10000}
      SURGE_MANAGED_CONFIG_BASE_URL: \${SURGE_MANAGED_CONFIG_BASE_URL:-}

    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

    env_file:
      - .env

  postgres:
    image: postgres:16-alpine

    container_name: ruleflow-postgres

    restart: unless-stopped

    environment:
      POSTGRES_DB: \${POSTGRES_DB:-ruleflow}
      POSTGRES_USER: \${POSTGRES_USER:-ruleflow}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}

    volumes:
      - pgdata:/var/lib/postgresql/data

    healthcheck:
      test: ["CMD-SHELL","pg_isready -U \${POSTGRES_USER:-ruleflow} -d \${POSTGRES_DB:-ruleflow}"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine

    container_name: ruleflow-redis

    restart: unless-stopped

    command: redis-server --requirepass \${REDIS_PASSWORD}

    healthcheck:
      test: ["CMD","redis-cli","-a","\${REDIS_PASSWORD}","ping"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  pgdata:
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ RuleFlow 已启动${RESET}"
    echo -e "${YELLOW}🌐 地址:${RESET} http://127.0.0.1:${PORT}/setup"
    echo -e "${YELLOW}🗄 PostgreSQL:${RESET} ${POSTGRES_USER}@${POSTGRES_DB}"
    echo -e "${YELLOW}🔐 PostgreSQL密码:${RESET} ${POSTGRES_PASSWORD}"
    echo -e "${YELLOW}🔐 Redis密码:${RESET} ${REDIS_PASSWORD}"
    echo -e "${YELLOW}📂 安装目录:${RESET} ${APP_DIR}"

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

    cd "$APP_DIR" || return

    docker compose ps

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已彻底卸载(含数据库数据)${RESET}"

    read -p "按回车返回菜单..."
}

menu
