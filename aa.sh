#!/bin/bash
# ========================================
# Watchtower 一键管理脚本 (Compose 安全版)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="watchtower"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}❌ Docker 未安装${RESET}"
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}❌ Docker Compose 未安装${RESET}"
        exit 1
    fi
}

show_usage() {
    echo -e "${GREEN}使用方法:${RESET}"
    echo -e "${YELLOW}docker run 命令里加一行:${RESET}"
    echo -e "${YELLOW}--label com.centurylinklabs.watchtower.enable=true${RESET}"
    echo -e "${GREEN}你必须在 docker compose 需要更新的容器里加:${RESET}"
    echo -e "${YELLOW}labels:${RESET}"
    echo -e "${YELLOW}  - \"com.centurylinklabs.watchtower.enable=true\"${RESET}"
    echo -e "${YELLOW}仅更新带 label 的容器${RESET}"
}

install_app() {
    check_docker

    mkdir -p $APP_DIR

    read -p "请输入 Telegram BotToken: " BOT_TOKEN
    read -p "请输入 Telegram ChatID: " CHAT_ID

    cat > $COMPOSE_FILE <<EOF
services:
  watchtower:
    image: ghcr.io/naiba-forks/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_URL: "telegram://${BOT_TOKEN}@telegram?chats=${CHAT_ID}&parseMode=Markdown"
      WATCHTOWER_NOTIFICATION_TEMPLATE: "{{range .}}{{.Time}} - {{.Level}} - {{.Message}}{{println}}{{end}}"
    command: --schedule "0 0 0 * * *"
EOF

    cd $APP_DIR
    docker compose up -d

    echo -e "${GREEN}✅ Watchtower 安装完成（每日0点检查更新）${RESET}" 
    show_usage
     
}

update_app() {
    cd $APP_DIR || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Watchtower 已更新${RESET}"
}

manual_run() {
    cd $APP_DIR || exit
    docker compose run --rm watchtower --run-once
}

restart_app() {
    cd $APP_DIR 2>/dev/null || {
        echo -e "${RED}❌ 未安装 Watchtower${RESET}"
        return
    }

    docker compose restart
    echo -e "${GREEN}✅ Watchtower 已重启${RESET}"
}

view_logs() {
    cd $APP_DIR 2>/dev/null || {
        echo -e "${RED}❌ 未安装 Watchtower${RESET}"
        return
    }

    echo -e "${YELLOW}按 Ctrl+C 退出日志查看${RESET}"
    docker compose logs -f --tail=100
}

uninstall_app() {
    cd $APP_DIR 2>/dev/null || exit
    docker compose down
    rm -rf $APP_DIR
    echo -e "${RED}❌ Watchtower 已卸载${RESET}"
}

show_menu() {
    while true; do
        clear
        echo -e "${GREEN}==== Watchtower 管理菜单 ==== ${RESET}"
        echo -e "${GREEN}1. 安装 Watchtower${RESET}"
        echo -e "${GREEN}2. 更新 Watchtower${RESET}"
        echo -e "${GREEN}3. 手动立即更新一次${RESET}"
        echo -e "${GREEN}4. 重启 Watchtower${RESET}"
        echo -e "${GREEN}5. 查看日志${RESET}"
        echo -e "${GREEN}6. 查看使用方法${RESET}"
        echo -e "${GREEN}7. 卸载 Watchtower${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) manual_run ;;
            4) restart_app ;;
            5) view_logs ;;
            6) show_usage ;; 
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ;;
        esac

        read -p "按回车返回菜单..." temp
    done
}

show_menu
