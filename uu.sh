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

    read -p "请输入监听端口 [默认随机]: " PORT
    [[ -z "$PORT" ]] && PORT=$(random_port)

    echo -e "${YELLOW}正在生成 2022 密钥...${RESET}"
    PASSWORD=$(openssl rand -base64 32)

    cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

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
EOF

    cd "$APP_DIR" || exit
    docker compose up -d
   

    IP4=$(hostname -I | awk '{print $1}')
    IP6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo
    echo "Shadowsocks Rust 配置："
    echo " 地址：$IP4"
    [[ -n "$IP6" ]] && echo " 地址：$IP6"
    echo " 端口：$PORT"
    echo " 密码：$PASSWORD"
    echo " 加密：$METHOD"
    echo " TFO ：true"
    echo "————————————————————————————————————————"
    BASE64_V4=$(echo -n "${METHOD}:${PASSWORD}@${IP4}:${PORT}" | base64 -w 0)
    SS_LINK_V4="ss://${BASE64_V4}"

    if [[ -n "$IPV6" ]]; then
       BASE64_V6=$(echo -n "${METHOD}:${PASSWORD}@[${IP6}]:${PORT}" | base64 -w 0)
       SS_LINK_V6="ss://${BASE64_V6}"
    fi
    echo "—————————————————————————"
    echo "[信息] Surge 配置："
    echo "$HOSTNAME = ss, $IP4,$PORT, encrypt-method=$METHOD, password=$PASSWORD, tfo=true, udp-relay=true, ecn=true"
    echo

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
