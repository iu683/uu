#!/bin/bash
# ========================================
# Shadowsocks Rust 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="shadowsocks-rust"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/compose.yml"
CONFIG_FILE="$APP_DIR/config.json"

METHOD="2022-blake3-aes-256-gcm"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi
    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Shadowsocks Rust 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker
    mkdir -p "$APP_DIR"

    random_port() {
        while :; do
            PORT=$(shuf -i 2000-65000 -n 1)
            ss -lnt | awk '{print $4}' | grep -q ":$PORT$" || break
        done
        echo "$PORT"
    }

    echo
    read -p "ShadowTLS 对外端口 [默认 443]: " TLS_PORT
    TLS_PORT=${TLS_PORT:-443}

    read -p "请输入伪装域名 SNI [默认 captive.apple.com]: " TLS_HOST
    TLS_HOST=${TLS_HOST:-captive.apple.com}

    # Shadowsocks 固定只监听本地
    SS_PORT=8388

    echo -e "${YELLOW}生成 Shadowsocks 密钥...${RESET}"
    SS_PASSWORD=$(openssl rand -base64 32)

    echo -e "${YELLOW}生成 ShadowTLS 密码...${RESET}"
    TLS_PASSWORD=$(openssl rand -base64 16)

    METHOD="2022-blake3-aes-256-gcm"

    # ================= SS 配置 =================
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

    # ================= Docker Compose =================
    cat > "$COMPOSE_FILE" <<EOF
services:
  ss:
    image: ghcr.io/shadowsocks/ssserver-rust:latest
    container_name: shadowsocks
    restart: unless-stopped
    network_mode: host
    command: ssserver -c /etc/shadowsocks/config.json
    volumes:
      - ./config.json:/etc/shadowsocks/config.json:ro

  shadow-tls:
    image: ghcr.io/ihciah/shadow-tls:latest
    container_name: shadow-tls
    restart: unless-stopped
    network_mode: host
    environment:
      - MODE=server
      - V3=1
      - LISTEN=0.0.0.0:${TLS_PORT}
      - SERVER=127.0.0.1:${SS_PORT}
      - TLS=${TLS_HOST}:443
      - PASSWORD=${TLS_PASSWORD}
EOF

    cd "$APP_DIR" || exit
    docker compose down
    docker compose up -d

    IP4=$(hostname -I | awk '{print $1}')

    echo
    echo "=============================="
    echo "Shadowsocks + ShadowTLS 已部署"
    echo "服务器IP: $IP4"
    echo "端口: $TLS_PORT"
    echo "加密方式: $METHOD"
    echo "SS密码: $SS_PASSWORD"
    echo "ShadowTLS密码: $TLS_PASSWORD"
    echo "SNI: $TLS_HOST"
    echo "=============================="

    # 生成 ss 链接
    BASE=$(echo -n "${METHOD}:${SS_PASSWORD}@${IP4}:${TLS_PORT}" | base64 -w 0)

    PLUGIN="shadow-tls%3Bhost%3D${TLS_HOST}%3Bpassword%3D${TLS_PASSWORD}%3Bv3%3D1"

    SS_LINK="ss://${BASE}?plugin=${PLUGIN}"

    echo
    echo "ShadowTLS 专用链接："
    echo "----------------------------------"
    echo "$SS_LINK"
    echo "----------------------------------"

    read -p "按回车返回菜单..."
}
update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Shadowsocks 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart shadowsocks
    echo -e "${GREEN}✅ Shadowsocks 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f shadowsocks
}

check_status() {
    docker ps | grep shadowsocks
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Shadowsocks 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
