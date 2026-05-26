#!/bin/bash
# ========================================
# Heart Xanadu Guide 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="heart-xanadu"
APP_DIR="/opt/$APP_NAME"

generate_secret() {
    openssl rand -hex 32
}

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

        echo -e "${GREEN}=== Heart Xanadu 管理菜单 ===${RESET}"
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
    read -p "请输入后台端口 [默认:3100]: " input_port
    APP_PORT=${input_port:-3100}

    read -p "请输入后台密码 ADMIN_PASSWORD: " ADMIN_PASSWORD

    SESSION_SECRET=$(generate_secret)

    cd /opt || exit

    git clone https://github.com/wnnif/Heart-Xanadu-personal-guide-1.0.git "$APP_NAME"

    cd "$APP_DIR" || exit

    cp .env.example .env

    sed -i "s#^SESSION_SECRET=.*#SESSION_SECRET=${SESSION_SECRET}#g" .env
    sed -i "s#^ADMIN_PASSWORD=.*#ADMIN_PASSWORD=${ADMIN_PASSWORD}#g" .env
    sed -i "s#^APP_PORT=.*#APP_PORT=${APP_PORT}#g" .env

    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ Heart Xanadu 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${APP_PORT}${RESET}"
    echo -e "${YELLOW}🌐 管理地址: http://127.0.0.1:${APP_PORT}/admin/${RESET}"
    echo -e "${YELLOW}🔐 密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${YELLOW}🔐 SESSION_SECRET: ${SESSION_SECRET}${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"

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
