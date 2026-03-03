#!/bin/bash
# ========================================
# Shadowsocks Rust+shadow-tls 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ShadowsocksRust+shadow-tls"
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
        echo -e "${GREEN}=== ShadowsocksRust+shadow-tls管理菜单 ===${RESET}"
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

    read -p "是否启用 IPv6 [true/false 默认 false]: " ipv6
    IPv6=${ipv6:-false}

    read -p "ShadowTLS 对外端口 [默认 8443]: " TLS_PORT
    TLS_PORT=${TLS_PORT:-8443}

    read -p "请输入伪装域名 SNI [默认 captive.apple.com]: " TLS_HOST
    TLS_HOST=${TLS_HOST:-captive.apple.com}

    read -p "Shadowsocks 内部监听端口 [默认随机]: " input_ss_port

    if [[ -z "$input_ss_port" ]]; then
        SS_PORT=$(shuf -i 20000-60000 -n1)
        echo "已生成随机端口: $SS_PORT"
    else
        SS_PORT=$input_ss_port
    fi

    echo -e "${YELLOW}生成 Shadowsocks 密钥...${RESET}"
    SS_PASSWORD=$(openssl rand -base64 32)

    echo -e "${YELLOW}生成 ShadowTLS 密码...${RESET}"
    TLS_PASSWORD=$(openssl rand -base64 16)

    METHOD="2022-blake3-aes-256-gcm"

    # ===== IPv6 / IPv4 地址逻辑 =====
    if [[ "$IPv6" == "true" ]]; then
        SS_BIND="::1"
        LISTEN_ADDR="[::]:${TLS_PORT}"
        SERVER_ADDR="[::1]:${SS_PORT}"
    else
        SS_BIND="127.0.0.1"
        LISTEN_ADDR="0.0.0.0:${TLS_PORT}"
        SERVER_ADDR="127.0.0.1:${SS_PORT}"
    fi

    # ================= SS 配置 =================
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "$SS_BIND",
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
      - LISTEN=${LISTEN_ADDR}
      - SERVER=${SERVER_ADDR}
      - TLS=${TLS_HOST}:443
      - PASSWORD=${TLS_PASSWORD}
EOF

    cd "$APP_DIR" || exit
    docker compose down 2>/dev/null
    docker compose up -d

    IP4=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo
    echo -e "${GREEN}Shadowsocks + ShadowTLS部署完成${RESET}"
    echo "=============================="
    echo "服务器IP: $IP4"
    echo "对外端口: $TLS_PORT"
    echo "加密方式: $METHOD"
    echo "SS密码: $SS_PASSWORD"
    echo "ShadowTLS密码: $TLS_PASSWORD"
    echo "SNI: $TLS_HOST"
    echo "IPv6模式: $IPv6"
    echo "=============================="
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${YELLOW}📄 V6VPS替换IP地址为V6⭐${RESET}"
    # 生成 ss 链接
    BASE=$(echo -n "${METHOD}:${SS_PASSWORD}@${IP4}:${TLS_PORT}" | base64 -w 0)

    PLUGIN="shadow-tls%3Bhost%3D${TLS_HOST}%3Bpassword%3D${TLS_PASSWORD}%3Bv3%3D1"

    SS_LINK="ss://${BASE}?plugin=${PLUGIN}"

    echo
    echo "ShadowTLS 专用链接："
    echo "----------------------------------"
    echo -e "${YELLOW}$SS_LINK${RESET}"
    echo "----------------------------------"
    echo "Surge配置:"
    echo -e "${YELLOW}$HOSTNAME = ss, $IP4, $TLS_PORT, encrypt-method=$METHOD, password=$SS_PASSWORD, shadow-tls-password=$TLS_PASSWORD, shadow-tls-sni=$TLS_HOST, shadow-tls-version=3, tfo=true, udp-relay=true, ecn=true ${RESET}"

    read -p "按回车返回菜单..."
}
update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ShadowsocksRust+shadow-tls 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ ShadowsocksRust+shadow-tls 全部已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    echo -e "${GREEN}=== 容器状态 ===${RESET}"
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ ShadowsocksRust+shadow-tls 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
