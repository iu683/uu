#!/bin/bash
# ========================================
# new-api 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
YELLOW="\033[33m"

APP_NAME="new-api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== new-api 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR"

    read -rp "请输入 Web 端口 [默认:3000]: " input_port
    WEB_PORT=${input_port:-3000}

    cat > "$COMPOSE_FILE" <<EOF

services:
  new-api:
    container_name: new-api
    image: calciumion/new-api:latest
    restart: always
    ports:
      - "127.0.0.1:$WEB_PORT:3000"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./data:/data
EOF

    echo "WEB_PORT=$WEB_PORT" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ new-api 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$WEB_PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ new-api 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ new-api 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ new-api 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f new-api
    read -p "按回车返回菜单..."
    menu
}

menu
