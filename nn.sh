#!/bin/bash
# ========================================
# Docker Run Notify 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="docker-run-notify"
APP_DIR="/opt/$APP_NAME"
REPO="https://github.com/SamHou0/docker-run-notify.git"
ENV_FILE="$APP_DIR/.env"

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

menu() {
    while true; do

        clear

        echo -e "${GREEN}=== Docker Run Notify 管理菜单 ===${RESET}"
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

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否重新安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    echo -e "${GREEN}正在克隆项目...${RESET}"

    git clone "$REPO" "$APP_DIR"

    cd "$APP_DIR" || exit

    cp .env.example .env

    echo
    echo -e "${GREEN}配置 Telegram 通知${RESET}"

    read -p "请输入 Telegram Bot Token: " BOT_TOKEN
    read -p "请输入 Telegram 用户ID (多个用逗号分隔): " USER_IDS
    read -p "通知延迟秒 [默认:30]: " input_delay

    DELAY=${input_delay:-30}

    sed -i "s/TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$BOT_TOKEN/" .env
    sed -i "s/TELEGRAM_USER_IDS=.*/TELEGRAM_USER_IDS=$USER_IDS/" .env
    sed -i "s/NOTIFICATION_DELAY_SECONDS=.*/NOTIFICATION_DELAY_SECONDS=$DELAY/" .env

    echo
    echo -e "${GREEN}正在构建 Docker 镜像...${RESET}"

    docker compose build

    echo -e "${GREEN}正在启动容器...${RESET}"

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Docker Run Notify 已启动${RESET}"
    echo -e "${GREEN}📢 Docker 容器运行状态将通过 Telegram 通知${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    echo -e "${GREEN}更新代码...${RESET}"

    git pull

    docker compose build
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

    docker ps | grep docker-run-notify

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down

    cd /

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已卸载 docker-run-notify${RESET}"

    read -p "按回车返回菜单..."
}

menu
