#!/bin/bash
# ========================================
# LangBot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="langbot"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/langbot-app/LangBot.git"
COMPOSE_DIR="$APP_DIR/LangBot/docker"

# 获取服务器IP
SERVER_IP=$(hostname -I | awk '{print $1}')

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
        echo -e "${GREEN}=== LangBot 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    if [ -d "$APP_DIR/LangBot" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf LangBot
    fi

    git clone "$REPO_URL"
    cd "$COMPOSE_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ LangBot 已启动${RESET}"
    echo -e "${GREEN}✅ webui http://${SERVER_IP}:5300${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR/LangBot" || { echo "未检测到安装目录"; sleep 1; return; }
    git pull
    cd docker || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$COMPOSE_DIR" || { echo "未检测到安装"; sleep 1; return; }
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$COMPOSE_DIR" || { echo "未检测到安装"; sleep 1; return; }
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker compose logs -f
}

check_status() {
    cd "$COMPOSE_DIR" || { echo "未检测到安装"; sleep 1; return; }
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$COMPOSE_DIR" || return
    docker compose down
    rm -rf "$APP_DIR/LangBot"
    echo -e "${RED}✅ LangBot 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
