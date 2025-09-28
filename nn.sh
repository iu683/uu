#!/bin/bash
# Music Player 一键管理脚本（支持自定义端口和管理员密码）

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="music-player"
BASE_DIR="/opt/music-player"
YML_FILE="$BASE_DIR/docker-compose.yml"

# 默认端口和管理员密码
DEFAULT_PORT=3000
DEFAULT_ADMIN_PASS="admin123"

create_compose() {
    local port=$1
    local admin_pass=$2

    mkdir -p "$BASE_DIR"

    cat > $YML_FILE <<EOF
services:
  music-player:
    image: ghcr.io/eooce/music-player:latest
    ports:
      - "127.0.0.1:${port}:3000"
    environment:
      - PORT=3000
      - ADMIN_PASSWORD=${admin_pass}
    volumes:
      - music-data:/app/music
    restart: unless-stopped

volumes:
  music-data:
EOF
}

show_menu() {
    echo -e "${GREEN}=== Music Player 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动服务${RESET}"
    echo -e "${GREEN}2) 停止服务${RESET}"
    echo -e "${GREEN}3) 启动服务${RESET}"
    echo -e "${GREEN}4) 重启服务${RESET}"
    echo -e "${GREEN}5) 更新服务${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载服务（含数据）${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
}

print_access_info() {
    local ip=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    echo -e "🌐 访问地址: ${GREEN}http://127.0.0.1:${PORT}${RESET}"
    echo -e "🔑 管理员密码: ${GREEN}${ADMIN_PASSWORD}${RESET}"
}

install_app() {
    read -p "请输入映射端口 (默认 ${DEFAULT_PORT}): " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    read -p "请输入管理员密码 (默认 ${DEFAULT_ADMIN_PASS}): " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASS}

    create_compose "$PORT" "$ADMIN_PASSWORD"
    docker compose -f $YML_FILE up -d
    echo -e "✅ ${GREEN}Music Player 已安装并启动${RESET}"
    print_access_info
}

stop_app() {
    docker compose -f $YML_FILE down
    echo -e "🛑 ${GREEN}Music Player 已停止${RESET}"
}

start_app() {
    docker compose -f $YML_FILE up -d
    echo -e "🚀 ${GREEN}Music Player 已启动${RESET}"
    print_access_info
}

restart_app() {
    docker compose -f $YML_FILE down
    docker compose -f $YML_FILE up -d
    echo -e "🔄 ${GREEN}Music Player 已重启${RESET}"
    print_access_info
}

update_app() {
    docker compose -f $YML_FILE pull
    docker compose -f $YML_FILE up -d
    echo -e "⬆️ ${GREEN}Music Player 已更新到最新版本${RESET}"
    print_access_info
}

logs_app() {
    docker logs -f $APP_NAME
}

uninstall_app() {
    docker compose -f $YML_FILE down
    rm -f $YML_FILE
    docker volume rm music-data
    echo -e "🗑️ ${GREEN}Music Player 已卸载，数据已删除${RESET}"
}

while true; do
    show_menu
    case $choice in
        1) install_app ;;
        2) stop_app ;;
        3) start_app ;;
        4) restart_app ;;
        5) update_app ;;
        6) logs_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "❌ ${GREEN}无效选择${RESET}" ;;
    esac
done
