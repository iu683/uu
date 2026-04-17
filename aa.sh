#!/bin/bash
# ========================================
# magnet_fix 管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="magnet_fix"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/poouo/magnet_fix.git"
COMPOSE_DIR="$APP_DIR/magnet_fix"

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
        echo -e "${GREEN}=== magnet_fix 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    if [ -d "$COMPOSE_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$COMPOSE_DIR"
    fi

    echo -e "${GREEN}正在拉取项目...${RESET}"
    git clone "$REPO_URL"

    cd "$COMPOSE_DIR" || exit

    docker compose up -d --build

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${YELLOW}🌐 搜索首页: http://${SERVER_IP}:8080${RESET}"
    echo -e "${YELLOW}🔐 管理后台: http://${SERVER_IP}:8080/admin${RESET}"
    echo -e "${YELLOW}🔐 默认密码: admin123${RESET}"

    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$COMPOSE_DIR" || return
    git pull
    docker compose up -d --build
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -rp "按回车返回菜单..."
}

restart_app() {
    cd "$COMPOSE_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    cd "$COMPOSE_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$COMPOSE_DIR" || return
    docker compose ps
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$COMPOSE_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载完成${RESET}"
    read -rp "按回车返回菜单..."
}

menu
