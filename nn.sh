#!/bin/bash
# ========================================
# WireGuard 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="wireguard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== WireGuard 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看客户端配置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) view_clients ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 WireGuard 端口 [默认:51820]: " input_port
    SERVERPORT=${input_port:-51820}

    read -p "请输入服务器公网域名或 IP: " SERVERURL
    read -p "请输入客户端数量 [默认:1]: " PEERS
    PEERS=${PEERS:-1}

    mkdir -p "$APP_DIR/config"

    cat > "$COMPOSE_FILE" <<EOF
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard1
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - SERVERURL=$SERVERURL
      - SERVERPORT=$SERVERPORT
      - PEERS=$PEERS
      - PEERDNS=auto
      - INTERNAL_SUBNET=192.168.18.0
      - ALLOWEDIPS=0.0.0.0/0
      - LOG_CONFS=true
    volumes:
      - $APP_DIR/config:/config
      - /lib/modules:/lib/modules
    ports:
      - "$SERVERPORT:$SERVERPORT/udp"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

    echo "SERVERPORT=$SERVERPORT" > "$CONFIG_FILE"
    echo "SERVERURL=$SERVERURL" >> "$CONFIG_FILE"
    echo "PEERS=$PEERS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    # 获取本机公网 IP
    IP=$(curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1")

    echo -e "${GREEN}✅ WireGuard 已启动${RESET}"
    echo -e "${GREEN}🌐 服务器地址: $SERVERURL:$SERVERPORT (公网 IP: $IP)${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ WireGuard 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ WireGuard 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f wireguard1
    read -p "按回车返回菜单..."
    menu
}

function view_clients() {
    echo -e "${GREEN}=== 客户端配置列表 ===${RESET}"
    for conf in $APP_DIR/config/peer*/peer*.conf; do
        [ -f "$conf" ] && echo "$conf"
    done
    echo -e "${GREEN}以上路径为客户端配置文件，可直接下载或复制${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
