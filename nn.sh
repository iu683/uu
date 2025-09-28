#!/bin/bash
# ========================================
# Web 本地构建服务 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="web-local"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== vps-value-calculator 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:8280]: " input_port
    PORT=${input_port:-8280}

    read -p "请输入持久化数据目录 [默认: $HOME/$APP_NAME/data]: " input_dir
    PERSIST_DIR=${input_dir:-$HOME/$APP_NAME}

    mkdir -p "$PERSIST_DIR/data" "$PERSIST_DIR/static/images"

    cat > "$COMPOSE_FILE" <<EOF
version: '3'
services:
  web:
    build: .
    container_name: $APP_NAME
    ports:
      - "127.0.0.1:$PORT:$PORT"
    volumes:
      - "$PERSIST_DIR/data:/app/data"
      - "$PERSIST_DIR/static/images:/app/static/images"
    restart: unless-stopped
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "PERSIST_DIR=$PERSIST_DIR" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose build
    docker compose up -d

    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $PERSIST_DIR/data${RESET}"
    echo -e "${GREEN}📂 图片目录: $PERSIST_DIR/static/images${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose build
    docker compose up -d
    echo -e "${GREEN}✅ ${APP_NAME} 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ ${APP_NAME} 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f $APP_NAME
    read -p "按回车返回菜单..."
    menu
}

menu
