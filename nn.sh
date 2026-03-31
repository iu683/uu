#!/bin/bash
# ========================================
# Transmission 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="transmission"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
        echo -e "${GREEN}=== Transmission 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
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

    mkdir -p "$APP_DIR/config"
    mkdir -p "$APP_DIR/downloads"
    mkdir -p "$APP_DIR/watch"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 WebUI 用户名 [默认:admin]: " input_user
    USERNAME=${input_user:-admin}

    read -p "请输入 WebUI 密码 [默认:admin123]: " input_pass
    PASSWORD=${input_pass:-admin123}

    cat > "$COMPOSE_FILE" <<EOF
services:
  transmission:
    image: linuxserver/transmission:latest
    container_name: transmission
    environment:
      - PUID=1000
      - PGID=1000
      - UMASK_SET=002
      - TZ=Asia/Shanghai
      - USER=${USERNAME}
      - PASS=${PASSWORD}
    volumes:
      - ./config:/config
      - ./downloads:/downloads
      - ./watch:/watch
    network_mode: host
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)
    echo
    echo -e "${GREEN}✅ Transmission 已启动${RESET}"
    echo -e "${YELLOW}🌐 WebUI: http://${SERVER_IP}:9091${RESET}"
    echo -e "${YELLOW}🌐 账号: ${USERNAME}${RESET}"
    echo -e "${YELLOW}🌐 密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 下载目录: $APP_DIR/downloads${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Transmission 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart transmission
    echo -e "${GREEN}✅ Transmission 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f transmission
}

check_status() {
    docker ps | grep transmission
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Transmission 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
