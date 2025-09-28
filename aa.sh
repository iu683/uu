#!/bin/bash
# ========================================
# Danmu-API 一键管理脚本 (Docker Compose + 随机 Token)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="danmu-api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 生成随机 Token
generate_token() {
    TOKEN=$(openssl rand -hex 16)
}

function menu() {
    clear
    echo -e "${GREEN}=== Danmu-API 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
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
    read -p "请输入 Web 端口 [默认:9321]: " input_port
    PORT=${input_port:-9321}

    # 创建统一文件夹
    mkdir -p "$APP_DIR/data"

    # 生成随机 Token
    generate_token

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  danmu-api:
    image: logvar/danmu-api:latest
    container_name: danmu-api
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:9321"
    environment:
      - TOKEN=$TOKEN
    volumes:
      - $APP_DIR/data:/app/data
EOF

    # 保存配置
    echo -e "PORT=$PORT\nTOKEN=$TOKEN" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Danmu-API 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 Token: $TOKEN${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    source "$CONFIG_FILE"
    echo -e "${GREEN}✅ Danmu-API 已更新并重启完成${RESET}"
    echo -e "${GREEN}🔑 Token: $TOKEN${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Danmu-API 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f danmu-api
    read -p "按回车返回菜单..."
    menu
}

menu
