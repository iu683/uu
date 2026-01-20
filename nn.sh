#!/bin/bash
# ========================================
# MiSub 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="misub"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== MiSub 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR/data"

    read -p "请输入 Web 端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    read -p "请输入 管理员密码 [默认:123456]: " input_admin
    ADMIN_PASSWORD=${input_admin:-123456}

    read -p "请输入 Cookie Secret [默认:123456]: " input_cookie
    COOKIE_SECRET=${input_cookie:-123456}

    cat > "$COMPOSE_FILE" <<EOF
services:
  misub:
    image: ghcr.io/imzyb/misub:latest
    container_name: misub
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8080"
    environment:
      PORT: 8080
      MISUB_DB_PATH: /app/data/misub.db
      ADMIN_PASSWORD: "\${ADMIN_PASSWORD}"
      COOKIE_SECRET: "\${COOKIE_SECRET}"
    volumes:
      - ./data:/app/data
EOF

    cd "$APP_DIR" || exit
    PORT=$PORT \
    ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    COOKIE_SECRET="$COOKIE_SECRET" \
    docker compose up -d

    echo -e "${GREEN}✅ MiSub 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🔐 管理员密码: $ADMIN_PASSWORD${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MiSub 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ MiSub 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f misub
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MiSub 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
