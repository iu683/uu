#!/bin/bash
# ========================================
# Xboard 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Xboard"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/compose.yaml"

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

        echo -e "${GREEN}=== Xboard 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then

        echo -e "${GREEN}开始克隆 Xboard...${RESET}"

        git clone https://github.com/cedar2025/Xboard.git "$APP_DIR"
    fi

    cd "$APP_DIR" || exit

    cp compose.sample.yaml compose.yaml

    echo
    read -p "请输入管理员邮箱 [默认:admin@demo.com]: " ADMIN_EMAIL

    ADMIN_EMAIL=${ADMIN_EMAIL:-admin@demo.com}

    echo
    echo -e "${GREEN}开始安装数据库...${RESET}"

    docker compose run -it --rm \
        -e ENABLE_SQLITE=true \
        -e ENABLE_REDIS=true \
        -e ADMIN_ACCOUNT="$ADMIN_EMAIL" \
        xboard php artisan xboard:install

    echo
    echo -e "${GREEN}启动 Xboard...${RESET}"

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Xboard 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:7001${RESET}"
    echo -e "${YELLOW}⚠️ 请保存安装显示的后台账号密码${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    git pull

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return

    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return

    docker compose logs -f
}

check_status() {

    cd "$APP_DIR" || return

    docker compose ps

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
