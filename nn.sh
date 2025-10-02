#!/bin/bash
# ========================================
# kuma-mieru 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="kuma-mieru"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/.env"
HOST_PORT=3883

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 用户运行脚本${RESET}"
        exit 1
    fi
}

install_app() {
    read -p "请输入 Uptime Kuma 地址 (例如 https://example.kuma-mieru.invalid): " UPTIME_KUMA_BASE_URL
    while [[ -z "$UPTIME_KUMA_BASE_URL" ]]; do
        echo -e "${RED}地址不能为空${RESET}"
        read -p "请输入 Uptime Kuma 地址: " UPTIME_KUMA_BASE_URL
    done

    read -p "请输入页面 ID: " PAGE_ID
    while [[ -z "$PAGE_ID" ]]; do
        echo -e "${RED}页面 ID 不能为空${RESET}"
        read -p "请输入页面 ID: " PAGE_ID
    done

    if [ -d "$APP_DIR" ]; then
        echo -e "${GREEN}检测到已有项目，拉取最新代码...${RESET}"
        cd "$APP_DIR"
        git pull
    else
        git clone https://github.com/Alice39s/kuma-mieru.git "$APP_DIR"
        cd "$APP_DIR"
    fi

    cp -f .env.example .env
    sed -i "s|^UPTIME_KUMA_BASE_URL=.*|UPTIME_KUMA_BASE_URL=${UPTIME_KUMA_BASE_URL}|" .env
    sed -i "s|^PAGE_ID=.*|PAGE_ID=${PAGE_ID}|" .env

    docker compose up -d

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}✅ 部署完成！${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:${HOST_PORT}${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}项目未安装，请先安装！${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    git pull
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}项目未安装，请先安装！${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    docker compose restart
    echo -e "${GREEN}✅ 服务已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}项目未安装，请先安装！${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    echo -e "${GREEN}日志输出（Ctrl+C 退出）...${RESET}"
    docker compose logs --tail 100 -f
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}项目未安装，无需卸载${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    docker compose down --rmi all -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载并删除数据${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu() {
    clear
    echo -e "${GREEN}=== kuma-mieru 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启服务${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ; menu ;;
    esac
}

check_root
menu
