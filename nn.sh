#!/bin/bash
# ======================================
# NodePass Server 一键管理脚本 (host 模式)
# ======================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nodepass-server"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== NodePass Server 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR"

    read -rp "请输入 master URL [默认 master://:10101/api?log=debug&tls=1]: " master_url
    MASTER_URL=${master_url:-master://:10101/api?log=debug&tls=1}

    cat > "$CONFIG_FILE" <<EOF
MASTER_URL=$MASTER_URL
EOF

    cat > "$COMPOSE_FILE" <<EOF

services:
  nodepass-server:
    image: ghcr.io/yosebyte/nodepass:latest
    container_name: nodepass-server
    network_mode: host
    restart: unless-stopped
    command: $MASTER_URL
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ NodePass Server 已启动${RESET}"
    echo -e "${GREEN}🌐 master URL: $MASTER_URL${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ NodePass Server 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ NodePass Server 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f nodepass-server
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
