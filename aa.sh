#!/bin/bash
# ========================================
# qbit-bot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="qbit-bot"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
        echo -e "${GREEN}=== qbit-bot 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo -e "${GREEN}=== 配置 qbit-bot ===${RESET}"

    read -p "请输入 qBittorrent 地址 [默认:http://127.0.0.1:8080]: " input_host
    QB_HOST=${input_host:-http://127.0.0.1:8080}

    read -p "请输入 qbit 用户名: " QB_USER
    read -p "请输入 qbit 密码: " QB_PASS
    read -p "请输入 Telegram Bot Token: " TG_TOKEN
    read -p "请输入 Telegram 用户ID: " TG_USER_ID

    cat > "$COMPOSE_FILE" <<EOF
services:
  qbit-bot:
    image: gblaowang12138/my_qbit_bot:latest
    container_name: my-qbit-bot
    restart: unless-stopped
    network_mode: "host"
    environment:
      QB_HOST: ${QB_HOST}
      QB_USER: ${QB_USER}
      QB_PASS: ${QB_PASS}
      TG_TOKEN: ${TG_TOKEN}
      TG_USER_ID: ${TG_USER_ID}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ qbit-bot 已启动${RESET}"
    echo -e "${YELLOW}👉 请先给机器人发送 /start${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart my-qbit-bot
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f my-qbit-bot
}

check_status() {
    docker ps | grep qbit-bot
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
