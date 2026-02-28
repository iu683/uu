#!/bin/bash
# ========================================
# Umami 一键管理脚本（稳定增强版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="umami"
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
        echo -e "${GREEN}=== Umami 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    DB_PASS=$(openssl rand -hex 12)
    APP_SECRET=$(openssl rand -hex 32)

    echo "DB_PASS=${DB_PASS}" > "$ENV_FILE"
    echo "APP_SECRET=${APP_SECRET}" >> "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  db:
    image: postgres:15-alpine
    container_name: umami-db
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: \${DB_PASS}
    volumes:
      - umami-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U umami"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: always

  umami:
    image: ghcr.io/umami-software/umami:latest
    container_name: umami
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      DATABASE_URL: postgresql://umami:\${DB_PASS}@db:5432/umami
      APP_SECRET: \${APP_SECRET}
    depends_on:
      db:
        condition: service_healthy
    restart: always
    init: true

volumes:
  umami-db-data:
EOF

    cd "$APP_DIR" || exit
    docker compose --env-file "$ENV_FILE" up -d

    echo -e "${YELLOW}⏳ 等待数据库就绪...${RESET}"
    until docker exec umami-db pg_isready -U umami &>/dev/null; do
        sleep 2
    done

    echo
    echo -e "${GREEN}✅ Umami 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔐 数据库名:  umami${RESET}"
    echo -e "${YELLOW}🔐 数据库用户:umami${RESET}"
    echo -e "${YELLOW}🔐 数据库密码:${DB_PASS}${RESET}"
    echo -e "${YELLOW}🔐 APP_SECRET:${APP_SECRET}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose --env-file "$ENV_FILE" pull
    docker compose --env-file "$ENV_FILE" up -d
    echo -e "${GREEN}✅ Umami 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart umami umami-db
    echo -e "${GREEN}✅ Umami 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f umami
}

check_status() {
    docker ps | grep umami
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose --env-file "$ENV_FILE" down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Umami 已卸载（含数据库数据）${RESET}"
    read -p "按回车返回菜单..."
}

menu
