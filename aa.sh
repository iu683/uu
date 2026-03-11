#!/bin/bash
# ========================================
# Telegram Web 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="telegram"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== Telegram Web 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo

    read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"

    read -p "请输入 Web 端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}

    read -p "请输入用户名 [默认:admin]: " input_user
    USER=${input_user:-admin}

    read -p "请输入密码 [默认:admin123]: " input_pass
    PASS=${input_pass:-admin123}

    read -p "请输入配置目录 [默认:/opt/telegram/config]: " input_config
    CONFIG_DIR=${input_config:-/opt/telegram/config}

    mkdir -p "$CONFIG_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  telegram:
    container_name: telegram
    image: lscr.io/linuxserver/telegram:latest
    security_opt:
      - seccomp=unconfined
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - TITLE=MyTelegram
      - CUSTOM_USER=${USER}
      - CUSTOM_PASSWORD=${PASS}
    ports:
      - 127.0.0.1:${PORT}:3000
    volumes:
      - ${CONFIG_DIR}:/config
    restart: always
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Telegram Web 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}👤 用户名: ${USER}${RESET}"
    echo -e "${GREEN}🔑 密码: ${PASS}${RESET}"
    echo -e "${GREEN}📂 配置目录: ${CONFIG_DIR}${RESET}"

    echo
    read -p "按回车返回菜单..."
    menu
}

update_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Telegram Web 已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

restart_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose restart

    echo -e "${GREEN}✅ Telegram Web 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

view_logs() {

    docker logs -f telegram

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose down
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Telegram Web 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

menu
