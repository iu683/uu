#!/bin/bash
# ========================================
# Cloud Manager 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="cloud-manager"
APP_DIR="/opt/$APP_NAME"

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
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear
        echo -e "${GREEN}===== Cloud Manager 管理菜单=====${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
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

    check_port 3001 || return

    mkdir -p /opt

    cd /opt || exit

    echo -e "${GREEN}正在克隆 Cloud Manager...${RESET}"

    git clone https://github.com/JenkinWoo/cloud-manager.git "$APP_DIR"

    cd "$APP_DIR" || exit

    echo -e "${GREEN}正在启动容器...${RESET}"

    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ Cloud Manager 安装完成${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:3001${RESET}"
    echo -e "${YELLOW}🌐 账号/密码: admin/admin123${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    echo -e "${GREEN}正在更新 Cloud Manager...${RESET}"

    git pull

    docker compose up -d --build

    echo -e "${GREEN}✅ Cloud Manager 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return

    docker compose restart

    echo -e "${GREEN}✅ Cloud Manager 已重启${RESET}"

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

    echo -e "${RED}✅ Cloud Manager 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
