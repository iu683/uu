#!/bin/bash
# ========================================
# Sub-Store 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="sub-store"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 随机生成 20 位密钥
function gen_key() {
    tr -dc 'a-z0-9' </dev/urandom | head -c20
}

function menu() {
    clear
    echo -e "${GREEN}=== Sub-Store 管理菜单 ===${RESET}"
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
    read -p "请输入宿主机端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}

    mkdir -p "$APP_DIR/data"

    # 随机生成 SUB_STORE_FRONTEND_BACKEND_PATH
    PATH_KEY=$(gen_key)

    cat > "$COMPOSE_FILE" <<EOF
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    volumes:
      - $APP_DIR/data:/opt/app/data
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$PATH_KEY
    ports:
      - "127.0.0.1:$PORT:3001"
    stdin_open: true
    tty: true
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "SUB_STORE_FRONTEND_BACKEND_PATH=/$PATH_KEY" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Sub-Store 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🌐 API: http://127.0.0.1:$PORT/$PATH_KEY${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Sub-Store 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Sub-Store 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f sub-store
    read -p "按回车返回菜单..."
    menu
}

menu
