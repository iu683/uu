#!/bin/bash
# Nezha Telegram Bot 一键管理脚本（可选择保留数据库）

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="nezhatgbot-v1"
BASE_DIR="$HOME/nezhabot"
IMAGE_NAME="ghcr.io/nezhahq/nezhatgbot-v1:latest"

show_menu() {
    echo -e "${GREEN}=== Nezha Telegram Bot 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动服务${RESET}"
    echo -e "${GREEN}2) 停止服务${RESET}"
    echo -e "${GREEN}3) 启动服务${RESET}"
    echo -e "${GREEN}4) 重启服务${RESET}"
    echo -e "${GREEN}5) 更新服务${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载服务（可选择保留数据库）${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    read -p "请选择: " choice
}

install_app() {
    read -p "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
    mkdir -p "$BASE_DIR"

    docker pull $IMAGE_NAME
    docker run -d --name $APP_NAME --restart unless-stopped \
        -e TELEGRAM_TOKEN="$TELEGRAM_TOKEN" \
        -e TZ="Asia/Shanghai" \
        -v "$BASE_DIR:/app/db" \
        $IMAGE_NAME

    echo -e "✅ ${GREEN}Nezha Telegram Bot 已安装并启动${RESET}"
}

stop_app() {
    docker stop $APP_NAME
    echo -e "🛑 ${GREEN}Nezha Telegram Bot 已停止${RESET}"
}

start_app() {
    docker start $APP_NAME
    echo -e "🚀 ${GREEN}Nezha Telegram Bot 已启动${RESET}"
}

restart_app() {
    docker restart $APP_NAME
    echo -e "🔄 ${GREEN}Nezha Telegram Bot 已重启${RESET}"
}

update_app() {
    docker pull $IMAGE_NAME
    docker stop $APP_NAME
    docker rm $APP_NAME
    docker run -d --name $APP_NAME --restart unless-stopped \
        -e TELEGRAM_TOKEN="$TELEGRAM_TOKEN" \
        -e TZ="Asia/Shanghai" \
        -v "$BASE_DIR:/app/db" \
        $IMAGE_NAME
    echo -e "⬆️ ${GREEN}Nezha Telegram Bot 已更新${RESET}"
}

logs_app() {
    docker logs -f $APP_NAME
}

uninstall_app() {
    read -p "是否保留数据库？(y保留/n删除，默认y): " keep_db
    keep_db=${keep_db:-y}

    docker stop $APP_NAME
    docker rm $APP_NAME

    if [[ "$keep_db" == "n" || "$keep_db" == "N" ]]; then
        rm -rf "$BASE_DIR"
        echo -e "🗑️ ${GREEN}Nezha Telegram Bot 已卸载，数据库已删除${RESET}"
    else
        echo -e "🗑️ ${GREEN}Nezha Telegram Bot 已卸载，数据库已保留在 $BASE_DIR${RESET}"
    fi
}

while true; do
    show_menu
    case $choice in
        1) install_app ;;
        2) stop_app ;;
        3) start_app ;;
        4) restart_app ;;
        5) update_app ;;
        6) logs_app ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "❌ ${GREEN}无效选择${RESET}" ;;
    esac
done
