#!/bin/bash
# Telegram Message Bot 管理脚本 (绿色菜单版)
# API 信息通过环境变量或 .env 文件提供，不再交互输入

SERVICE_NAME="telegram-message-bot"
INSTALL_DIR="/opt/$SERVICE_NAME"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# 颜色
GREEN="\e[32m"
RESET="\e[0m"

install() {
    echo -e "${GREEN}>>> 开始安装 Telegram Message Bot...${RESET}"

    read -p "请输入映射端口 (默认 9393): " PORT
    PORT=${PORT:-9393}

    read -p "请输入时区 (默认 Asia/Shanghai): " TZ
    TZ=${TZ:-Asia/Shanghai}

    mkdir -p "$INSTALL_DIR"/{data,logs,sessions,temp}

    cat > $COMPOSE_FILE <<EOF
version: '3.8'

services:
  telegram-message-bot:
    image: hav93/telegram-message-bot:latest
    container_name: telegram-message-bot
    restart: always
    ports:
      - "$PORT:9393"
    environment:
      - TZ=$TZ
      - ENABLE_PROXY=false
      - DATABASE_URL=sqlite:///data/bot.db
      - LOG_LEVEL=INFO
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
      - ./sessions:/app/sessions
      - ./temp:/app/temp
EOF

    cd "$INSTALL_DIR"
    docker compose up -d

    # 获取服务器IP
    IP=$(curl -s ifconfig.me)
    if [ -z "$IP" ]; then
        IP=$(hostname -I | awk '{print $1}')
    fi

    echo -e "${GREEN}>>> Telegram Message Bot 已安装并运行在: http://$IP:$PORT${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}


start() {
    cd "$INSTALL_DIR" && docker compose up -d
    echo -e "${GREEN}>>> Telegram Message Bot 已启动${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

stop() {
    cd "$INSTALL_DIR" && docker compose down
    echo -e "${GREEN}>>> Telegram Message Bot 已停止${RESET}"
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
    echo -e "${GREEN}>>> Telegram Message Bot 已更新${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

uninstall() {
    stop
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}>>> Telegram Message Bot 已卸载${RESET}"
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
    menu
}

menu() {
    clear
    echo -e "${GREEN}======================${RESET}"
    echo -e "${GREEN} Telegram Bot 管理菜单${RESET}"
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
