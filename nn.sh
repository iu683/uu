#!/bin/bash
# ========================================
# Qianlian + Postgres 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="qianlian"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
    if ss -tlnp 2>/dev/null | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Qianlian 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

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
    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -rp "请输入访问端口 [默认:8000]: " input_port
    PORT=${input_port:-8000}
    check_port "$PORT" || return

    read -rp "请输入管理员密码 [默认:admin123]: " input_admin
    ADMIN_PASSWORD=${input_admin:-admin123}

    read -rp "请输入数据库密码 [默认:change-this-password]: " input_dbpass
    DB_PASS=${input_dbpass:-change-this-password}

    POSTGRES_DB="bailian"
    POSTGRES_USER="bailian"

    SESSION_SECRET=$(openssl rand -hex 16 2>/dev/null || date +%s%N | md5sum | head -c 32)

    cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: bailian-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  qianlian-proxy:
    image: ghcr.io/yumusb/qianlian:latest
    container_name: qianlian-proxy
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy

    ports:
      - "127.0.0.1:${PORT}:8000"

    volumes:
      - ./data:/app/data

    environment:
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      DATABASE_URL: postgresql://${POSTGRES_USER}:${DB_PASS}@postgres:5432/${POSTGRES_DB}
      TRUST_PROXY_HEADERS: "false"
      APP_TIMEZONE: Asia/Shanghai
      SECURITY_PATH_PREFIX: qianlian

    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8000/health || curl -f http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

volumes:
  postgres-data:
EOF

    docker compose up -d

    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 访问密码: $ADMIN_PASSWORD${RESET}"
    echo -e "${GREEN}📁 路径: $APP_DIR${RESET}"

    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -rp "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -rp "按回车返回菜单..."
}

menu
