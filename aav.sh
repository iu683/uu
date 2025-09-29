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

# 自动安装 qrencode
if ! command -v qrencode &>/dev/null; then
    echo -e "${GREEN}📦 安装 qrencode 用于生成二维码${RESET}"
    if command -v apt &>/dev/null; then
        apt update && apt install -y qrencode
    elif command -v yum &>/dev/null; then
        yum install -y qrencode
    fi
fi

function menu() {
    clear
    echo -e "${GREEN}=== WireGuard 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看客户端配置与二维码${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) view_client ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 WireGuard 服务端口 [默认:51820]: " input_port
    SERVERPORT=${input_port:-51820}

    read -p "请输入客户端数量 [默认:1]: " input_peers
    PEERS=${input_peers:-1}

    read -p "请输入公网域名 [默认:$(curl -s ifconfig.me)]: " input_ip
    SERVERURL=${input_ip:-$(curl -s ifconfig.me)}

    read -p "请输入 IPv4 内网段 [默认:192.168.18.0]: " input_subnet
    INTERNAL_SUBNET=${input_subnet:-192.168.18.0}

    read -p "请输入 IPv6 内网段 [默认:fd00:1234:5678::/64]: " input_subnet_v6
    INTERNAL_SUBNET_V6=${input_subnet_v6:-fd00:1234:5678::/64}

    read -p "请输入允许访问的 IP 范围 [默认:0.0.0.0/0,::/0]: " input_allowed
    ALLOWEDIPS=${input_allowed:-0.0.0.0/0,::/0}

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
      - INTERNAL_SUBNET=$INTERNAL_SUBNET
      - INTERNAL_SUBNET_V6=$INTERNAL_SUBNET_V6
      - ALLOWEDIPS=$ALLOWEDIPS
      - PERSISTENTKEEPALIVE_PEERS=
      - LOG_CONFS=true
    volumes:
      - $APP_DIR/config:/config
      - /lib/modules:/lib/modules
    ports:
      - "$SERVERPORT:$SERVERPORT/udp"
      - "[::]:$SERVERPORT:$SERVERPORT/udp"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    restart: unless-stopped
EOF

    echo "SERVERPORT=$SERVERPORT" > "$CONFIG_FILE"
    echo "PEERS=$PEERS" >> "$CONFIG_FILE"
    echo "SERVERURL=$SERVERURL" >> "$CONFIG_FILE"
    echo "INTERNAL_SUBNET=$INTERNAL_SUBNET" >> "$CONFIG_FILE"
    echo "INTERNAL_SUBNET_V6=$INTERNAL_SUBNET_V6" >> "$CONFIG_FILE"
    echo "ALLOWEDIPS=$ALLOWEDIPS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ WireGuard 已启动${RESET}"
    echo -e "${GREEN}🌐 公网访问地址: $SERVERURL:$SERVERPORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}🌐 IPv4 内网段: $INTERNAL_SUBNET${RESET}"
    echo -e "${GREEN}🌐 IPv6 内网段: $INTERNAL_SUBNET_V6${RESET}"
    echo -e "${GREEN}🌐 允许访问的 IP: $ALLOWEDIPS${RESET}"
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

# 显示每个客户端的配置和二维码
function view_clients() {
    echo -e "${GREEN}=== 客户端配置列表 ===${RESET}"
    PEER_DIR="$APP_DIR/config/peer*"
    COUNT=0
    for conf in $PEER_DIR/peer*.conf; do
        if [ -f "$conf" ]; then
            COUNT=$((COUNT+1))
            echo -e "${GREEN}客户端 #$COUNT 配置文件: $conf${RESET}"
            echo -e "${GREEN}📱 扫码连接:${RESET}"
            qrencode -t ansiutf8 < "$conf"
            echo "-----------------------------------------"
        fi
    done
    if [ $COUNT -eq 0 ]; then
        echo -e "${GREEN}⚠️ 暂无客户端配置，请先安装或增加客户端${RESET}"
    fi
    read -p "按回车返回菜单..."
    menu
}

menu
