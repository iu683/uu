#!/bin/bash
# ========================================
# AutoBangumi 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
CONFIG_DIR="/opt/AutoBangumi/config"
DATA_DIR="/opt/AutoBangumi/data"
COMPOSE_FILE="/opt/AutoBangumi/docker-compose.yml"
ENV_FILE="/opt/AutoBangumi/.env"

function menu() {
    clear
    echo -e "${GREEN}=== AutoBangumi 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新 AutoBangumi${RESET}"
    echo -e "${GREEN}3) 卸载 AutoBangumi${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
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
    read -p "请输入映射端口 (默认 7892): " input_port
    APP_PORT=${input_port:-7892}

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"

    echo "PUID=$(id -u)" > "$ENV_FILE"
    echo "PGID=$(id -g)" >> "$ENV_FILE"
    echo "APP_PORT=$APP_PORT" >> "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF

services:
  autobangumi:
    image: ghcr.io/estrellaxd/auto_bangumi:latest
    container_name: autobangumi
    restart: unless-stopped
    network_mode: bridge
    ports:
      - "127.0.0.1:${APP_PORT}:7892"
    environment:
      - TZ=Asia/Shanghai
      - PUID=\${PUID}
      - PGID=\${PGID}
      - UMASK=022
    volumes:
      - ${CONFIG_DIR}:/app/config
      - ${DATA_DIR}:/app/data
    dns:
      - 8.8.8.8
EOF

    cd "$HOME/AutoBangumi"
    docker compose up -d
    echo -e "✅ 已启动 AutoBangumi"
    echo -e "🌐 访问地址: ${GREEN}http://127.0.0.1:${APP_PORT}${RESET}"
    echo -e "👤 默认用户名: ${GREEN}admin${RESET}"
    echo -e "🔑 默认密码: ${GREEN}adminadmin${RESET}"
    echo -e "📂 配置目录: ${GREEN}$CONFIG_DIR${RESET}"
    echo -e "📂 数据目录: ${GREEN}$DATA_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$HOME/AutoBangumi" || exit
    docker compose pull
    docker compose up -d
    echo "✅ AutoBangumi 已更新并重启完成"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$HOME/AutoBangumi" || exit
    docker compose down -v
    rm -rf "$HOME/AutoBangumi"
    echo "✅ AutoBangumi 已彻底卸载（含数据与配置）"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f autobangumi
    read -p "按回车返回菜单..."
    menu
}

menu
