#!/bin/bash
# ========================================
# WG-Easy 高级版 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="wg-easy"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# 获取服务器IP
SERVER_IP=$(curl -s --max-time 2 ifconfig.me)
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip route get 1 | awk '{print $7;exit}')



menu() {
    clear
    echo -e "${GREEN}=== WG-Easy 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新镜像${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "请选择: " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) docker logs -f wg-easy ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

install_app() {

    mkdir -p "$APP_DIR"

    read -p "Web 管理端口 [默认 51821]: " web_port
    read -p "WireGuard UDP 端口 [默认 51820]: " wg_port
    read -p "管理密码 (必填): " PASSWORD

    WEB_PORT=${web_port:-51821}
    WG_PORT=${wg_port:-51820}

    cat > "$COMPOSE_FILE" <<EOF

volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    environment:
      - PASSWORD=${PASSWORD}
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:51820/udp"
      - "${WEB_PORT}:51821/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ WG-Easy 已启动${RESET}"
    echo -e "${YELLOW}Web UI: http://${SERVER_IP}:${WEB_PORT}${RESET}"
    echo -e "${GREEN}数据卷: etc_wireguard${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR"
    docker compose pull
    docker compose up -d
    menu
}

restart_app() {
    cd "$APP_DIR"
    docker compose restart
    menu
}

uninstall_app() {

    echo -e "${YELLOW}🛑 停止并删除容器 + 数据卷...${RESET}"

    cd "$APP_DIR" 2>/dev/null || true
    docker compose down -v 2>/dev/null

    echo -e "${YELLOW}🗑 删除 $APP_DIR 目录...${RESET}"
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ WG-Easy 已彻底卸载完成${RESET}"

    sleep 2
    menu
}

menu
