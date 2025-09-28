#!/bin/bash
# ========================================
# Foxel 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="foxel"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Foxel 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看密钥${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) show_secret ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:8088]: " input_port
    PORT=${input_port:-8088}

    # 可自定义密钥
    read -p "请输入 SECRET_KEY [留空自动生成]: " input_secret
    SECRET_KEY=${input_secret:-$(openssl rand -base64 32)}

    # 创建统一文件夹
    mkdir -p "$APP_DIR/data"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  foxel:
    image: ghcr.io/drizzletime/foxel:latest
    container_name: foxel
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:80"
    environment:
      - TZ=Asia/Shanghai
      - SECRET_KEY=$SECRET_KEY
      - TEMP_LINK_SECRET_KEY=$SECRET_KEY
    volumes:
      - $APP_DIR/data:/app/data
    pull_policy: always
    networks:
      - foxel-network

networks:
  foxel-network:
    driver: bridge
EOF

    echo -e "PORT=$PORT\nSECRET_KEY=$SECRET_KEY" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Foxel 已启动${RESET}"
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
    echo -e "${GREEN}✅ Foxel 已更新并重启完成${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Foxel 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f foxel
    read -p "按回车返回菜单..."
    menu
}

function show_secret() {
    source "$CONFIG_FILE"
    echo -e "${GREEN}🔑 当前 SECRET_KEY: $SECRET_KEY${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
