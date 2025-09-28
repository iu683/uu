#!/bin/bash
# ========================================
# Telegram Message Bot 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="telegram-message-bot"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Telegram Message Bot 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:9393]: " input_port
    PORT=${input_port:-9393}

    mkdir -p "$APP_DIR"/{data,logs,sessions,temp,config}

    cat > "$COMPOSE_FILE" <<EOF

services:
  telegram-message-bot:
    image: hav93/telegram-message-bot:4.0.0
    container_name: telegram-message-bot
    restart: always
    ports:
      - "127.0.0.1:$PORT:9393"
    environment:
      - TZ=Asia/Shanghai
      - ENABLE_PROXY=false
      - PUID=1000
      - PGID=1000
      - DATABASE_URL=sqlite:///data/bot.db
      - LOG_LEVEL=INFO
    volumes:
      - $APP_DIR/data:/app/data
      - $APP_DIR/logs:/app/logs
      - $APP_DIR/sessions:/app/sessions
      - $APP_DIR/temp:/app/temp
      - $APP_DIR/config:/app/config
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Telegram Message Bot 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    source "$CONFIG_FILE"
    echo -e "${GREEN}✅ Telegram Message Bot 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Telegram Message Bot 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f telegram-message-bot
    read -p "按回车返回菜单..."
    menu
}

menu
