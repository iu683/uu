#!/bin/bash
# ========================================
# TGTLDR 一键管理脚本（官方模板版）
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
    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    read -p "请输入绑定地址 [默认:127.0.0.1]: " input_bind
    BIND=${input_bind:-127.0.0.1}

    read -p "请输入访问地址(带 http/https) [默认:http://localhost:${PORT}]: " input_origin
    WEB_ORIGIN=${input_origin:-http://localhost:${PORT}}

    read -p "请输入 PostgreSQL 密码 [默认:postgres]: " input_dbpass
    DB_PASS=${input_dbpass:-postgres}

    MASTER_KEY=$(openssl rand -hex 32)

    # 生成 .env
    cat > .env <<EOF
TGTLDR_MASTER_KEY=${MASTER_KEY}
TGTLDR_HOST_BIND=${BIND}
TGTLDR_HOST_WEB_PORT=${PORT}
TGTLDR_WEB_ORIGIN=${WEB_ORIGIN}
TGTLDR_IMAGE_NAMESPACE=fr0der1c
TGTLDR_IMAGE_TAG=latest
EOF

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: tgtldr
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - postgres-data:/var/lib/postgresql/data

  app:
    image: ${TGTLDR_IMAGE_NAMESPACE:-fr0der1c}/tgtldr-app:${TGTLDR_IMAGE_TAG:-latest}
    environment:
      TGTLDR_DATABASE_URL: postgres://postgres:postgres@postgres:5432/tgtldr?sslmode=disable
      TGTLDR_MASTER_KEY: ${TGTLDR_MASTER_KEY:-}
      TGTLDR_MASTER_KEY_FILE: /var/lib/tgtldr/master.key
      TGTLDR_WEB_ORIGIN: http://localhost:${TGTLDR_HOST_WEB_PORT:-3000}
      TGTLDR_HTTP_ADDR: :8080
    depends_on:
      - postgres
    volumes:
      - app-data:/var/lib/tgtldr

  web:
    image: ${TGTLDR_IMAGE_NAMESPACE:-fr0der1c}/tgtldr-web:${TGTLDR_IMAGE_TAG:-latest}
    environment:
      TGTLDR_INTERNAL_API_BASE_URL: http://app:8080
    depends_on:
      - app
    ports:
      - "${TGTLDR_HOST_BIND:-127.0.0.1}:${TGTLDR_HOST_WEB_PORT:-3000}:3000"

volumes:
  app-data:
  postgres-data:
EOF

    docker compose up -d

    echo
    echo -e "${GREEN}✅ TGTLDR 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 访问地址: ${WEB_ORIGIN}${RESET}"
    echo -e "${YELLOW}🔑 MASTER_KEY:$MASTER_KEY${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR${RESET}"

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
