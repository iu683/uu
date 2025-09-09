#!/bin/bash
# ============================================
# TGBot_RSS 一键管理脚本
# 功能: 安装/更新/卸载/查看日志
# ============================================

APP_NAME="TGBot_RSS"
IMAGE_NAME="kwxos/tgbot-rss:latest"
DATA_DIR="./TGBot_RSS"

GREEN="\033[32m"
RESET="\033[0m"

check_env() {
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

install_app() {
    read -p "请输入 Telegram Bot Token: " BOT_TOKEN
    read -p "请输入管理员 UID (0 表示所有用户可用): " ADMINIDS
    read -p "请输入 RSS 检查周期 (分钟，默认 1): " CYCLETIME
    CYCLETIME=${CYCLETIME:-1}
    read -p "是否开启调试模式 (true/false，默认 false): " DEBUG
    DEBUG=${DEBUG:-false}
    read -p "请输入代理服务器 URL (例如 http://127.0.0.1:7890, 默认空): " PROXYURL
    read -p "请输入推送接口 URL (默认空): " PUSHINFO

    mkdir -p "$DATA_DIR"

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME ...${RESET}"

    docker run -d \
      --name $APP_NAME \
      -e BotToken="$BOT_TOKEN" \
      -e ADMINIDS="$ADMINIDS" \
      -e Cycletime="$CYCLETIME" \
      -e Debug="$DEBUG" \
      -e ProxyURL="$PROXYURL" \
      -e Pushinfo="$PUSHINFO" \
      -e TZ="Asia/Shanghai" \
      -v "$(realpath $DATA_DIR):/root/" \
      $IMAGE_NAME

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
}

update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
    echo -e "${GREEN}✅ 容器已更新并启动${RESET}"
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 并删除数据吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker stop $APP_NAME && docker rm $APP_NAME
        rm -rf $DATA_DIR
        echo -e "${GREEN}✅ $APP_NAME 已卸载并清理${RESET}"
    else
        echo -e "${GREEN}❌ 已取消${RESET}"
    fi
}

logs_app() {
    docker logs -f $APP_NAME
}

menu() {
    clear
    echo -e "${GREEN}=== TGBot_RSS 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 TGBot_RSS${RESET}"
    echo -e "${GREEN}2) 更新 TGBot_RSS${RESET}"
    echo -e "${GREEN}3) 卸载 TGBot_RSS${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) logs_app ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择${RESET}" ;;
    esac
}

check_env
while true; do
    menu
    read -p "按回车键返回菜单..." enter
done
