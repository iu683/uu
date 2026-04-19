#!/bin/bash
# ========================================
# GithubStarsManager 管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="github-stars-manager"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/AmintaCCCP/GithubStarsManager.git"

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

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
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
        echo -e "${GREEN}=== GithubStarsManager 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装部署${RESET}"
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

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否重新安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    git clone "$REPO_URL" "$APP_DIR" || {
        echo -e "${RED}克隆失败${RESET}"
        return
    }

    cd "$APP_DIR" || exit

    docker compose up -d --build

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${YELLOW}🌐 前端: http://${SERVER_IP}:8080${RESET}"
    echo -e "${YELLOW}🌐 后端: http://${SERVER_IP}:3000${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    git pull
    docker compose up -d --build
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart github-stars-manager 2>/dev/null || docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    echo -e "${YELLOW}=== 容器状态 ===${RESET}"
    docker ps | grep stars

    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
