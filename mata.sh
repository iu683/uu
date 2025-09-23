#!/bin/bash
# Telegram Monitor 管理脚本 (绿色菜单版)

SERVICE_NAME="telegram-monitor"
INSTALL_DIR="/opt/$SERVICE_NAME"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

install() {
    echo -e "${GREEN}>>> 开始安装 Telegram Monitor...${RESET}"

    read -p "请输入映射端口 (默认 5005): " PORT
    PORT=${PORT:-5005}

    mkdir -p "$INSTALL_DIR/data"

    cat > $COMPOSE_FILE <<EOF
version: '3.8'

services:
  telegram-monitor:
    image: ghcr.io/riniba/telegrammonitor:latest
    container_name: $SERVICE_NAME
    restart: unless-stopped
    ports:
      - "$PORT:5005"
    volumes:
      - ./data:/app/data
    environment:
      - ASPNETCORE_ENVIRONMENT=Production
EOF

    cd "$INSTALL_DIR"
    docker compose up -d

    # 获取服务器IP
    IP=$(curl -s ifconfig.me)
    if [ -z "$IP" ]; then
        IP=$(hostname -I | awk '{print $1}')
    fi

    echo -e "${GREEN}>>> Telegram Monitor 已安装并运行在: http://$IP:$PORT${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

start() {
    cd "$INSTALL_DIR" && docker compose up -d
    echo -e "${GREEN}>>> Telegram Monitor 已启动${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

stop() {
    cd "$INSTALL_DIR" && docker compose down
    echo -e "${GREEN}>>> Telegram Monitor 已停止${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

restart() {
    stop
    start
}

update() {
    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}>>> Telegram Monitor 已更新${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

uninstall() {
    stop
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}>>> Telegram Monitor 已卸载${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

menu() {
    clear
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} Telegram Monitor 管理菜单${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 启动${RESET}"
    echo -e "${GREEN}3. 停止${RESET}"
    echo -e "${GREEN}4. 重启${RESET}"
    echo -e "${GREEN}5. 更新${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read CHOICE
    case $CHOICE in
        1) install ;;
        2) start ;;
        3) stop ;;
        4) restart ;;
        5) update ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}" ; sleep 1 ; menu ;;
    esac
}

menu
