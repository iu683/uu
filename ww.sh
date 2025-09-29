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

# 检测并安装 qrencode
function check_qrencode() {
    if ! command -v qrencode >/dev/null 2>&1; then
        echo -e "${GREEN}🔄 检测到 qrencode 未安装，正在安装...${RESET}"
        if [ -f /etc/debian_version ]; then
            apt update && apt install -y qrencode
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache qrencode
        elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
            yum install -y qrencode
        else
            echo -e "${GREEN}⚠️ 系统不支持自动安装 qrencode，请手动安装${RESET}"
        fi
    fi
}

# 获取公网 IP
function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== WireGuard 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看客户端配置和二维码${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
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
    check_qrencode

    read -p "请输入 WireGuard 服务端口 [默认:51820]: " input_port
    PORT=${input_port:-51820}

    read -p "请输入客户端数量 [默认:1]: " input_peers
    PEERS=${input_peers:-1}

    read -p "请输入内部子网 [默认:192.168.18.0]: " input_subnet
    INTERNAL_SUBNET=${input_subnet:-192.168.18.0}

    read -p "请输入允许客户端访问 IP 范围 [默认:0.0.0.0/0]: " input_allowed
    ALLOWEDIPS=${input_allowed:-0.0.0.0/0}

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
      - SERVERURL=$(get_ip)
      - SERVERPORT=$PORT
      - PEERS=$PEERS
      - PEERDNS=auto
      - INTERNAL_SUBNET=$INTERNAL_SUBNET
      - ALLOWEDIPS=$ALLOWEDIPS
      - PERSISTENTKEEPALIVE_PEERS=
      - LOG_CONFS=true
    volumes:
      - $APP_DIR/config:/config
      - /lib/modules:/lib/modules
    ports:
      - "$PORT:$PORT/udp"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "PEERS=$PEERS" >> "$CONFIG_FILE"
    echo "INTERNAL_SUBNET=$INTERNAL_SUBNET" >> "$CONFIG_FILE"
    echo "ALLOWEDIPS=$ALLOWEDIPS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ WireGuard 已启动${RESET}"
    echo -e "${GREEN}🌐 公网 IP: $(get_ip) 端口: $PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}👤 客户端数量: $PEERS  内部子网: $INTERNAL_SUBNET  允许访问: $ALLOWEDIPS${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    source "$CONFIG_FILE"
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
