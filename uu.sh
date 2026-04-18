#!/bin/bash
# ========================================
# Aria2 一键管理脚本（Host网络版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="aria2"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Aria2 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

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
    mkdir -p "$APP_DIR/config" "$APP_DIR/downloads"
    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -rp "请输入 RPC 密钥 [留空自动生成]: " input_token

    if [ -z "$input_token" ]; then
        if command -v openssl &>/dev/null; then
            TOKEN=$(openssl rand -hex 16)
    else
            TOKEN=$(date +%s%N | md5sum | head -c 32)
        fi
        echo -e "${GREEN}已生成随机 Token: ${TOKEN}${RESET}"
    else
        TOKEN="$input_token"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  aria2:
    image: superng6/aria2:webui-latest
    container_name: aria2
    network_mode: host
    restart: unless-stopped
    environment:
      PUID: 0
      PGID: 0
      TZ: Asia/Shanghai
      SECRET: ${TOKEN}
      CACHE: 512M
      WEBUI: "false"
    volumes:
      - ./config:/config
      - ./downloads:/downloads
EOF

    docker compose pull || {
        echo -e "${RED}❌ 镜像拉取失败${RESET}"
        return
    }

    docker compose up -d

    echo
    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}✅ Aria2 已启动（Host模式）${RESET}"
    echo -e "${YELLOW}🌐 地址: http://${SERVER_IP}:6080/jsonrpc${RESET}"
    echo -e "${YELLOW}🔑 RPC Token: ${TOKEN}${RESET}"
    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -rp "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -rp "按回车返回菜单..."
}

menu
