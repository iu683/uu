#!/bin/bash
# ========================================
# TGTLDR 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tgtldr"
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
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== TGTLDR 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "请选择: " choice

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

    mkdir -p "$APP_DIR/data/postgres"
    mkdir -p "$APP_DIR/data/app"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    read -p "请输入 PostgreSQL 密码 [默认:StrongPass123!]: " input_dbpass
    DB_PASS=${input_dbpass:-StrongPass123!}

    MASTER_KEY=$(openssl rand -hex 32)

    cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: postgres:17-alpine
    container_name: tgtldr-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: tgtldr
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data

  app:
    image: fr0der1c/tgtldr-app:latest
    container_name: tgtldr-app
    restart: unless-stopped
    environment:
      TGTLDR_DATABASE_URL: postgres://postgres:${DB_PASS}@postgres:5432/tgtldr?sslmode=disable
      TGTLDR_MASTER_KEY: ${MASTER_KEY}
      TGTLDR_MASTER_KEY_FILE: /var/lib/tgtldr/master.key
      TGTLDR_WEB_ORIGIN: http://127.0.0.1:${PORT}
      TGTLDR_HTTP_ADDR: :8080
    depends_on:
      - postgres
    volumes:
      - ./data/app:/var/lib/tgtldr

  web:
    image: fr0der1c/tgtldr-web:latest
    container_name: tgtldr-web
    restart: unless-stopped
    environment:
      TGTLDR_INTERNAL_API_BASE_URL: http://app:8080
    depends_on:
      - app
    ports:
      - "127.0.0.1:${PORT}:3000"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ TGTLDR 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${YELLOW}🔑 MASTER_KEY: ${MASTER_KEY}${RESET}"
    echo -e "${YELLOW}⚠️ 请妥善保存 MASTER_KEY，否则数据不可恢复！${RESET}"

    echo "${MASTER_KEY}" > "$APP_DIR/master.key"

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
    docker restart tgtldr-web tgtldr-app tgtldr-postgres
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f tgtldr-web
}

check_status() {
    docker ps | grep tgtldr
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
