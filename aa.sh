#!/bin/bash
# ========================================
# S-UI 一键管理脚本（Host 网络版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="s-ui"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_root() {

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 权限运行${RESET}"
        exit 1
    fi
}

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    systemctl enable docker --now &>/dev/null

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
        echo -e "${GREEN}=== S-UI 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 停止${RESET}"
        echo -e "${GREEN}5) 查看日志${RESET}"
        echo -e "${GREEN}6) 查看状态${RESET}"
        echo -e "${GREEN}7) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) stop_app ;;
            5) view_logs ;;
            6) check_status ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_root
    check_docker

    mkdir -p "$APP_DIR/db"
    mkdir -p "$APP_DIR/cert"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  s-ui:
    stdin_open: true

    tty: true

    container_name: s-ui

    restart: unless-stopped

    network_mode: host

    volumes:
      - ./db:/app/db
      - ./cert:/app/cert

    image: alireza7/s-ui:latest

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose pull
    docker compose up -d

    SERVER_IP=$(get_public_ip)


    echo
    echo -e "${GREEN}✅ S-UI 已启动${RESET}"
    echo -e "${YELLOW}🌐 面板地址: http://${SERVER_IP}:2095/app/${RESET}"
    echo -e "${YELLOW}🔌 订阅地址: http://${SERVER_IP}:2096${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR/db${RESET}"
    echo -e "${YELLOW}🔐 证书目录: $APP_DIR/cert${RESET}"
    echo -e "${YELLOW}🔒 面板证书设置: /app/cert/cert.crt${RESET}"
    echo -e "${YELLOW}📂 面板证书设置: /app/cert/private.key${RESET}"
  

    read -p "按回车返回菜单..."
}

update_app() {

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}未安装 S-UI${RESET}"
        sleep 2
        return
    fi

    cd "$APP_DIR" || return

    docker compose pull
    docker compose down
    docker compose up -d

    echo
    echo -e "${GREEN}✅ 更新完成${RESET}"
    echo

    read -p "按回车返回菜单..."
}

restart_app() {

    if ! docker ps -a | grep -q "s-ui"; then
        echo -e "${RED}容器不存在${RESET}"
        sleep 2
        return
    fi

    docker restart s-ui

    echo
    echo -e "${GREEN}✅ 已重启${RESET}"
    echo

    read -p "按回车返回菜单..."
}

stop_app() {

    cd "$APP_DIR" || return

    docker compose down

    echo
    echo -e "${YELLOW}✅ 已停止${RESET}"
    echo

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f --tail=100 s-ui
}

check_status() {


    docker ps -a | grep s-ui


    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v

    docker rm -f s-ui 2>/dev/null
    docker rmi alireza7/s-ui:latest 2>/dev/null

    rm -rf "$APP_DIR"

    echo
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    echo

    read -p "按回车返回菜单..."
}

menu
