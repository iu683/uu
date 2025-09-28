#!/bin/bash
# ========================================
# MoviePilot 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="moviepilot-v2"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== MoviePilot 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:3000]: " input_web
    PORT_WEB=${input_web:-3000}
    read -p "请输入 API 端口 [默认:3001]: " input_api
    PORT_API=${input_api:-3001}
    read -p "请输入超级管理员密码 [默认:admin123]: " SUPERPASS
    SUPERPASS=${SUPERPASS:-admin123}

    # 创建统一目录
    mkdir -p "$APP_DIR/config" "$APP_DIR/core" "$APP_DIR/media"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  moviepilot:
    image: jxxghp/moviepilot-v2:latest
    container_name: moviepilot-v2
    stdin_open: true
    tty: true
    restart: always
    volumes:
      - $APP_DIR/config:/config
      - $APP_DIR/core:/moviepilot/.cache/ms-playwright
      - $APP_DIR/media:/media
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NGINX_PORT=3000
      - PORT=3001
      - PUID=0
      - PGID=0
      - UMASK=000
      - TZ=Asia/Shanghai
      - SUPERUSER=admin
      - SUPERUSER_PASSWORD=$SUPERPASS
    ports:
      - "127.0.0.1:$PORT_WEB:3000"
      - "$PORT_API:3001"
EOF

    echo "PORT_WEB=$PORT_WEB" > "$CONFIG_FILE"
    echo "PORT_API=$PORT_API" >> "$CONFIG_FILE"
    echo "SUPERPASS=$SUPERPASS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ MoviePilot 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT_WEB${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MoviePilot 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ MoviePilot 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f moviepilot-v2
    read -p "按回车返回菜单..."
    menu
}

menu
