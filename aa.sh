#!/bin/bash
# ========================================
# NodeSeek RSS Telegram Bot 一键管理脚本
# Debian 12 / Ubuntu 兼容
# Docker Compose 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="nodeseek-rss-telegram-bot"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/AI-XMLY/nodeseek-rss-telegram-bot.git"

function menu() {
    clear
    echo -e "${GREEN}=== NodeSeek RSS Telegram Bot 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}


function check_docker() {
    
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 docker compose 插件，请检查 Docker 安装${RESET}"
        exit 1
    fi
}

function install_app() {
    echo -e "${YELLOW}开始安装 NodeSeek RSS Telegram Bot...${RESET}"

    check_docker

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone "$REPO_URL" "$APP_DIR"
    else
        echo -e "${YELLOW}检测到已存在项目目录，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit 1

    if [ ! -f ".env" ]; then
        cp .env.example .env
    fi

    echo
    echo -e "${GREEN}请填写配置${RESET}"
    read -p "请输入 BOT_TOKEN: " BOT_TOKEN
    read -p "请输入 BOT_OWNER_IDS(多个逗号分隔，可留空): " BOT_OWNER_IDS
    read -p "请输入 RSS_URL [默认: https://rss.nodeseek.com/]: " RSS_URL
    read -p "请输入轮询间隔秒数 [默认: 180]: " POLL_INTERVAL_SECONDS

    RSS_URL=${RSS_URL:-https://rss.nodeseek.com/}
    POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-180}

    sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=$BOT_TOKEN|" .env
    sed -i "s|^BOT_OWNER_IDS=.*|BOT_OWNER_IDS=$BOT_OWNER_IDS|" .env
    sed -i "s|^RSS_URL=.*|RSS_URL=$RSS_URL|" .env
    sed -i "s|^POLL_INTERVAL_SECONDS=.*|POLL_INTERVAL_SECONDS=$POLL_INTERVAL_SECONDS|" .env

    mkdir -p "$APP_DIR/data"

    echo -e "${GREEN}启动容器...${RESET}"
    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ 安装完成并已启动${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }

    echo -e "${GREEN}更新程序...${RESET}"
    git pull

    echo -e "${GREEN}重新构建并启动容器...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose logs -f
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function stop_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose down
    echo -e "${GREEN}✅ 已停止${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose down
    fi

    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
