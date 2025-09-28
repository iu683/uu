#!/bin/bash
# ========================================
# ZDir 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="zdir"
COMPOSE_DIR="/opt/zdir"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== ZDir 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
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
    read -p "请输入访问端口 [默认:6080]: " input_port
    PORT=${input_port:-6080}

    mkdir -p "$COMPOSE_DIR/data" "$COMPOSE_DIR/data/public" "$COMPOSE_DIR/data/private"

    cat > "$COMPOSE_FILE" <<EOF

services:
    zdir:
        container_name: zdir
        privileged: true
        image: helloz/zdir:4
        restart: always
        ports:
            - '127.0.0.1:$PORT:6080'
        volumes:
            - '${COMPOSE_DIR}/data:/opt/zdir/data'
            - '${COMPOSE_DIR}/data/public:/opt/zdir/data/public'
            - '${COMPOSE_DIR}/data/private:/opt/zdir/data/private'
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d
    echo -e "${GREEN}✅ ZDir 已启动，访问地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $COMPOSE_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ZDir 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose down -v
    rm -rf "$COMPOSE_DIR"
    echo -e "${GREEN}✅ ZDir 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f zdir
    read -p "按回车返回菜单..."
    menu
}

menu
