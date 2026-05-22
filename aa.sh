#!/bin/bash
# ========================================
# Telegram Drive Bot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="telegram-drive-bot"
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

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== Telegram Drive Bot 管理菜单 ===${RESET}"
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
    read -p "请输入 BOT_TOKEN(Telegram BotToken): " BOT_TOKEN
    read -p "请输入 OWNER_ID(Telegram ID): " OWNER_ID
    read -p "请输入 DATABASE_URL(PostgreSQL连接串 支持Supabase): " DATABASE_URL

    echo
    read -p "是否启用代理？(y/n): " enable_proxy

    if [[ "$enable_proxy" == "y" ]]; then
        read -p "请输入 PROXY_URL: " PROXY_URL
    fi

    echo
    read -p "是否启用频道存储模式？(y/n): " enable_channel

    if [[ "$enable_channel" == "y" ]]; then
        USE_CHANNEL_STORAGE=true

        read -p "请输入 STORAGE_CHAT_IDS(逗号分隔): " STORAGE_CHAT_IDS
    else
        USE_CHANNEL_STORAGE=false
    fi

    cd /opt || exit

    git clone https://github.com/Merack/telegram-drive-bot.git

    cd "$APP_DIR" || exit

    cp .env.example .env

    sed -i "s#^BOT_TOKEN=.*#BOT_TOKEN=${BOT_TOKEN}#g" .env

    sed -i "s#^OWNER_ID=.*#OWNER_ID=${OWNER_ID}#g" .env

    sed -i "s#^DATABASE_URL=.*#DATABASE_URL=${DATABASE_URL}#g" .env

    sed -i "s#^USE_CHANNEL_STORAGE=.*#USE_CHANNEL_STORAGE=${USE_CHANNEL_STORAGE}#g" .env

    if [[ -n "$STORAGE_CHAT_IDS" ]]; then
        sed -i "s#^#STORAGE_CHAT_IDS=${STORAGE_CHAT_IDS}\n#" .env
    fi

    if [[ -n "$PROXY_URL" ]]; then
        sed -i "s#^#PROXY_URL=${PROXY_URL}\n#" .env
    fi

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Telegram Drive Bot 已启动${RESET}"
    echo -e "${YELLOW}📂 安装目录:${RESET} $APP_DIR"
    echo -e "${YELLOW}⚙️ 配置文件:${RESET} $APP_DIR/.env"

    if [[ "$USE_CHANNEL_STORAGE" == "true" ]]; then
        echo -e "${GREEN}✅ 已启用频道存储模式${RESET}"
    fi

    if [[ -n "$PROXY_URL" ]]; then
        echo -e "${GREEN}✅ 已启用代理${RESET}"
    fi

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
