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
SERVER_IP=$(hostname -I | awk '{print $1}')


menu() {
    clear
    echo -e "${GREEN}=== WG-Easy 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新镜像${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

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
    echo

    if [ -z "$PASSWORD" ]; then
        echo -e "${RED}❌ 密码不能为空${RESET}"
        sleep 2
        menu
        return
    fi

    WEB_PORT=${web_port:-51821}
    WG_PORT=${wg_port:-51820}

    echo -e "${YELLOW}🔐 正在生成 bcrypt 密码...${RESET}"

    PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:15 wgpw "$PASSWORD")

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
      - PASSWORD_HASH=${PASSWORD_HASH}
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0,::/0
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

    echo -e "${GREEN}✅ WG-Easy v15 已启动${RESET}"
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

#!/bin/bash
# ========================================
# LX Sync Server 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="lxserver"
CONTAINER_NAME="lx-sync-server"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_env() {
    command -v docker >/dev/null 2>&1 || {
        echo -e "${RED}❌ 未检测到 Docker${RESET}"
        exit 1
    }
}

menu() {
    clear
    echo -e "${GREEN}=== LX Sync Server 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

install_app() {

    mkdir -p "$APP_DIR/data"
    mkdir -p "$APP_DIR/logs"

    read -p "服务端口 [默认 9527]: " input_port
    PORT=${input_port:-9527}

    cat > "$COMPOSE_FILE" <<EOF

services:
  lxserver:
    image: ghcr.io/xcq0607/lxserver:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:9527"
    volumes:
      - "$APP_DIR/data:/server/data"
      - "$APP_DIR/logs:/server/logs"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ LX Server 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 默认密码: 123456${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📂 日志目录: $APP_DIR/logs${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { menu; }
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    echo -e "${YELLOW}Ctrl+C 退出日志${RESET}"
    docker logs -f ${CONTAINER_NAME}
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

check_env
menu
