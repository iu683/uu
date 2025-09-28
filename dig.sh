#!/bin/bash
# ========================================
# Sub-Store 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="sub-store"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 获取本机IP
function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
}

# 生成随机路径
function random_path() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20
}

# 菜单
function menu() {
    clear
    echo -e "${GREEN}=== Sub-Store 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===========================${RESET}"
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

# 安装/启动
function install_app() {
    read -p "请输入 Web 端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}

    mkdir -p "$APP_DIR/sub-store-data"

    BACKEND_PATH=$(random_path)

    cat > "$COMPOSE_FILE" <<EOF

services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: always
    volumes:
      - $APP_DIR/sub-store-data:/opt/app/data
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=$BACKEND_PATH
    ports:
      - "127.0.0.1:$PORT:3001"
    stdin_open: true
    tty: true
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "SUB_STORE_FRONTEND_BACKEND_PATH=$BACKEND_PATH" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Sub-Store 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 后端路径: /$BACKEND_PATH${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/sub-store-data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 更新
function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Sub-Store 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 卸载
function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Sub-Store 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 查看日志
function view_logs() {
    docker logs -f sub-store
    read -p "按回车返回菜单..."
    menu
}

menu
