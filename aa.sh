#!/bin/bash
# ========================================
# sub2api 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

APP_NAME="sub2api"
APP_DIR="/opt/sub2api-deploy"
COMPOSE_FILE="$APP_DIR/docker-compose.local.yml"

# ==============================
# 必须 root
# ==============================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
# ==============================
# 工具函数
# ==============================

pause(){
    read -p "按回车返回菜单..."
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    else
        echo -e "${RED}未检测到 docker-compose，请安装 Docker Compose${RESET}"
        exit 1
    fi
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${BLUE}=== sub2api 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装/重装${RESET}"
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

# ==============================
# 功能函数
# ==============================

install_app() {

    check_docker

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo -e "${GREEN}正在下载官方部署脚本...${RESET}"
    curl -sSL https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-deploy.sh | bash

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}部署文件生成失败！${RESET}"
        pause
        return
    fi

    $COMPOSE_CMD -f docker-compose.local.yml up -d

    echo
    echo -e "${GREEN}✅ sub2api 已启动${RESET}"
    echo -e "${GREEN}✅ webui http://${SERVER_IP}:8080${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    pause
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    $COMPOSE_CMD -f docker-compose.local.yml pull
    $COMPOSE_CMD -f docker-compose.local.yml up -d
    echo -e "${GREEN}✅ sub2api 更新完成${RESET}"
    pause
}

restart_app() {
    cd "$APP_DIR" || return
    $COMPOSE_CMD -f docker-compose.local.yml restart
    echo -e "${GREEN}✅ sub2api 已重启${RESET}"
    pause
}

view_logs() {
    cd "$APP_DIR" || return
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    $COMPOSE_CMD -f docker-compose.local.yml logs -f sub2api
}

check_status() {
    if docker ps | grep -q sub2api; then
        echo -e "${GREEN}sub2api 服务运行中${RESET}"
    else
        echo -e "${RED}sub2api 服务未运行${RESET}"
    fi
    pause
}

uninstall_app() {
    cd "$APP_DIR" || return
    echo -e "${RED}正在彻底卸载并删除所有数据...${RESET}"
    $COMPOSE_CMD -f docker-compose.local.yml down -v 2>/dev/null
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ sub2api 已彻底卸载${RESET}"
    pause
}

menu
