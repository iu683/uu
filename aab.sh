#!/bin/bash
# ========================================
# Metatube 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="metatube"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function get_ip() {
    echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== Metatube 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    read -p "请输入 Postgres 密码 [默认:metatube]: " DB_PASS
    DB_PASS=${DB_PASS:-metatube}

    mkdir -p "$APP_DIR/config" "$APP_DIR/db" "$APP_DIR/run"

    cat > "$COMPOSE_FILE" <<EOF

services:
  metatube:
    image: ghcr.io/metatube-community/metatube-server:latest
    container_name: metatube
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:$PORT:8080"
    environment:
      - HTTP_PROXY=
      - HTTPS_PROXY=
    volumes:
      - $APP_DIR/run:/var/run
      - $APP_DIR/config:/config
    command: >
      -dsn "postgres://metatube:$DB_PASS@/metatube?host=/var/run/postgresql"
      -port 8080
      -db-auto-migrate
      -db-prepared-stmt

  postgres:
    image: postgres:15-alpine
    container_name: metatube-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=metatube
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=metatube
    volumes:
      - $APP_DIR/db:/var/lib/postgresql/data
      - $APP_DIR/run:/var/run
    command: >
      -c TimeZone=Asia/Shanghai
      -c log_timezone=Asia/Shanghai
      -c listen_addresses=''
      -c unix_socket_permissions=0777

volumes:
  run:
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "DB_PASS=$DB_PASS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Metatube 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}📂 数据库目录: $APP_DIR/db${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Metatube 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Metatube 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f metatube
    read -p "按回车返回菜单..."
    menu
}

menu
