#!/bin/bash
# ========================================
# LibreTV 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="libretv"
COMPOSE_DIR="$HOME/LibreTV"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== LibreTV 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
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
    read -p "请输入映射端口 [默认:8899]: " input_port
    PORT=${input_port:-8899}

    read -p "请输入访问密码 [默认:111111]: " input_pwd
    PASSWORD=${input_pwd:-111111}

    mkdir -p "$COMPOSE_DIR"

    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  libretv:
    image: bestzwei/libretv:latest
    container_name: libretv
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    environment:
      - PASSWORD=${PASSWORD}
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d
    echo -e "${GREEN}✅ LibreTV 已启动${RESET}"
    echo -e "${GREEN}🌐 访问地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}🔑 访问密码: $PASSWORD${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ LibreTV 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose down -v
    rm -rf "$COMPOSE_DIR"
    echo -e "${GREEN}✅ LibreTV 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f libretv
    read -p "按回车返回菜单..."
    menu
}

menu
