#!/bin/bash
# ========================================
# qBittorrent 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="qbittorrent"
COMPOSE_DIR="$HOME/qbittorrent"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== qBittorrent 管理菜单 ===${RESET}"
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
    read -p "请输入 Web UI 端口 [默认:8082]: " input_port
    WEB_PORT=${input_port:-8082}

    read -p "请输入 Torrent 传输端口 [默认:6881]: " input_tport
    TORRENT_PORT=${input_tport:-6881}

    mkdir -p "$COMPOSE_DIR/config" "$COMPOSE_DIR/downloads"

    cat > "$COMPOSE_FILE" <<EOF
version: '3'
services:
  qbittorrent:
    image: linuxserver/qbittorrent
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "${TORRENT_PORT}:${TORRENT_PORT}"
      - "${TORRENT_PORT}:${TORRENT_PORT}/udp"
      - "${WEB_PORT}:8080"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
    volumes:
      - ${COMPOSE_DIR}/config:/config
      - ${COMPOSE_DIR}/downloads:/downloads
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d
    echo -e "${GREEN}✅ qBittorrent 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$WEB_PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $COMPOSE_DIR/config${RESET}"
    echo -e "${GREEN}📂 下载目录: $COMPOSE_DIR/downloads${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ qBittorrent 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose down -v
    rm -rf "$COMPOSE_DIR"
    echo -e "${GREEN}✅ qBittorrent 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f qbittorrent
    read -p "按回车返回菜单..."
    menu
}

menu
