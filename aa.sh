#!/bin/bash
# ========================================
# IP Query Web 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ip-query-web"
APP_DIR="/opt/$APP_NAME"

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

check_port() {

    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== IP Query Web 管理菜单 ===${RESET}"
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

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    echo
    read -p "请输入端口 [默认:6688]: " input_port
    PORT=${input_port:-6688}
    check_port "$PORT" || return

    read -p "监听地址 HOST [默认:127.0.0.1]: " input_host
    HOST=${input_host:-127.0.0.1}

    read -p "公共DNS [默认:8.8.8.8,8.8.4.4]: " input_dns
    PUBLIC_DNS=${input_dns:-8.8.8.8,8.8.4.4}

    read -p "Github镜像 [默认:https://gh-proxy.com/]: " input_mirror
    GITHUB_MIRROR=${input_mirror:-https://gh-proxy.com/}

    cd /opt || exit

    git clone https://github.com/zeruns/ip-query-web.git "$APP_NAME"

    cd "$APP_DIR" || exit

    cat > .env <<EOF
PORT=${PORT}
HOST=${HOST}

RATE_LIMIT_MAX=120
RATE_LIMIT_DNS=30
RATE_LIMIT_PAGE=120

CC_MAX_CONCURRENT=20
CC_BURST_WINDOW=2000
CC_BURST_MAX=40
CC_SLOW_TIMEOUT=30000
CC_BLOCK_DURATION=60000

PUBLIC_DNS=${PUBLIC_DNS}

DATA_DIR=./data
LOG_LEVEL=info

GITHUB_MIRROR=${GITHUB_MIRROR}
EOF

    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ IP Query Web 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://${HOST}:${PORT}"
    echo -e "${YELLOW}🛰 Public DNS:${RESET} ${PUBLIC_DNS}"
    echo -e "${YELLOW}📂 安装目录:${RESET} $APP_DIR"

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
