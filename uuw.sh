#!/bin/bash
# ========================================
# Sun Panel 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="sun-panel"
COMPOSE_DIR="$HOME/sun-panel"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DEFAULT_PORT=3002

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== sun-panel 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:${DEFAULT_PORT}]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    mkdir -p "$COMPOSE_DIR/conf"

    cat > "$COMPOSE_FILE" <<EOF
version: '3.2'
services:
  sun-panel:
    image: hslr/sun-panel:latest
    container_name: sun-panel
    restart: always
    ports:
      - "${PORT}:3002"
    volumes:
      - ${COMPOSE_DIR}/conf:/app/conf
      - /var/run/docker.sock:/var/run/docker.sock
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $COMPOSE_DIR/conf${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ${APP_NAME} 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose down -v
    rm -rf "$COMPOSE_DIR"
    echo -e "${GREEN}✅ ${APP_NAME} 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f sun-panel
    read -p "按回车返回菜单..."
    menu
}

menu
