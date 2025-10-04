#!/bin/bash
# ========================================
# Xboard 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xboard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

function menu() {
    clear
    echo -e "${GREEN}=== Xboard 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR" && cd "$APP_DIR" || exit

    # 输入 Web 端口
    read -p "请输入 Web 端口 [默认:7001]: " input_port
    PORT=${input_port:-7001}

    # 写入 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  xboard:
    image: ghcr.io/cedar2025/xboard:latest
    container_name: xboard
    restart: unless-stopped
    environment:
      - docker=true
    ports:
      - "127.0.0.1:$PORT:7001"
    volumes:
      - ./.env:/www/.env
    depends_on:
      - mariadb
      - redis
EOF

    # 创建空白 .env 文件
    [ ! -f ".env" ] && touch .env

    # 初始化数据库
    docker compose run -it --rm xboard php artisan xboard:install

    # 启动服务
    docker compose up -d

    echo -e "${GREEN}✅ Xboard 已安装并启动${RESET}"
    echo -e "${YELLOW}🌐 Web 访问地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${YELLOW}🌐 数据库 ROOT 密码: $DB_PASS${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose run -it --rm xboard php artisan xboard:update
    docker compose up -d
    echo -e "${GREEN}✅ Xboard 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose down
    docker compose up -d
    echo -e "${GREEN}✅ Xboard 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    cd "$APP_DIR" || exit
    docker compose logs -f
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Xboard 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
