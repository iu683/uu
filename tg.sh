#!/bin/bash
# ========================================
# NodeSeeker 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="nodeseeker"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== NodeSeeker 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -ne "${GREEN}请选择: ${RESET}"
    read choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {
        read -p "请输入 Web 端口 [默认:3010]: " input_port
        PORT=${input_port:-3010}
        echo "PORT=$PORT" > "$CONFIG_FILE"
    mkdir -p "$APP_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  nodeseeker:
    image: ersichub/nodeseeker:latest
    container_name: nodeseeker
    ports:
      - "127.0.0.1:$PORT:3010"
    volumes:
      - $APP_DIR/data:/usr/src/app/data
    restart: unless-stopped
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ NodeSeeker 已启动${RESET}"
    echo -e "${GREEN}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo -e "${GREEN}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ NodeSeeker 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo -e "${GREEN}未检测到安装目录${RESET}"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ NodeSeeker 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f nodeseeker
    read -p "按回车返回菜单..."
    menu
}

menu
