#!/bin/bash
# ========================================
# Proxysudo 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

APP_NAME="proxysudo"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/GongyiChuren/proxysudo.git"

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tln | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Proxysudo 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case "$choice" in
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
        read -r confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    git clone "$REPO_URL" "$APP_DIR" || return
    cd "$APP_DIR" || return

    read -p "请输入端口 [默认:4877]: " input_port
    PORT=${input_port:-4877}
    check_port "$PORT" || return

    echo
    echo "1) 仅本地访问 (127.0.0.1)"
    echo "2) 公网访问 (0.0.0.0)"
    read -p "请选择 [默认:1]: " bind_choice

    if [[ "$bind_choice" == "2" ]]; then
        BIND_PORT="${PORT}:4877"
        ACCESS="公网"
    else
        BIND_PORT="127.0.0.1:${PORT}:4877"
        ACCESS="本地"
    fi

    sed -i -E \
        "s#- \"(127\.0\.0\.1:)?[0-9]+:4877\"#- \"$BIND_PORT\"#g" \
        docker-compose.yml

    docker compose pull
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Proxysudo 已启动${RESET}"
    echo -e "${GREEN}访问类型: ${ACCESS}${RESET}"

    if [[ "$ACCESS" == "公网" ]]; then
        echo -e "${YELLOW}🌐 访问地址: http://服务器IP:${PORT}${RESET}"
    else
        echo -e "${YELLOW}🌐 本地访问: http://127.0.0.1:${PORT}${RESET}"
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
    docker ps | grep proxysudo
    read -p "按回车返回菜单..."
}


uninstall_app() {

    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
