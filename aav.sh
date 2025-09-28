#!/bin/bash
# =========================================
# IPTV-4gtv 一键管理脚本（统一 /opt 目录 + 绿色菜单）
# 支持安装 / 更新 / 重启 / 停止 / 卸载 / 查看日志
# =========================================

APP_NAME="iptv-4gtv"
IMAGE_NAME="instituteiptv/iptv-4gtv:latest"
BASE_DIR="/opt/$APP_NAME"
CONFIG_FILE="$BASE_DIR/$APP_NAME.conf"

GREEN="\033[32m"
RESET="\033[0m"

check_env() {
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

get_ip() {
    if command -v curl &> /dev/null; then
        curl -s ifconfig.me
    elif command -v wget &> /dev/null; then
        wget -qO- ifconfig.me
    else
        echo "127.0.0.1"
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        PORT=50017
    fi
}

save_config() {
    mkdir -p "$BASE_DIR"
    echo "PORT=\"$PORT\"" > "$CONFIG_FILE"
}

install_app() {
    load_config

    read -p "请输入映射端口 (默认 ${PORT}): " input
    PORT=${input:-$PORT}
    save_config

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME ...${RESET}"

    docker rm -f $APP_NAME 2>/dev/null
    docker run -d \
      --name=$APP_NAME \
      -p 127.0.0.1:$PORT:5050 \
      --restart=always \
      $IMAGE_NAME

    SERVER_IP=$(get_ip)
    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${GREEN}📺 订阅地址: http://127.0.0.1:${PORT}/?type=m3u${RESET}"
}

update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
    echo -e "${GREEN}✅ 容器已更新并启动${RESET}"
}

restart_app() {
    echo -e "${GREEN}🔄 正在重启 $APP_NAME ...${RESET}"
    docker restart $APP_NAME
    echo -e "${GREEN}✅ 重启完成${RESET}"
}

stop_app() {
    echo -e "${GREEN}⏹ 正在停止 $APP_NAME ...${RESET}"
    docker stop $APP_NAME
    echo -e "${GREEN}✅ 停止完成${RESET}"
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 并删除配置吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker stop $APP_NAME && docker rm $APP_NAME
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}✅ $APP_NAME 已卸载并清理${RESET}"
    else
        echo -e "${GREEN}❌ 已取消${RESET}"
    fi
}

view_logs() {
    echo -e "${GREEN}📄 正在查看 $APP_NAME 日志 (Ctrl+C 退出)...${RESET}"
    docker logs -f $APP_NAME
}

menu() {
    clear
    echo -e "${GREEN}=== IPTV-4gtv 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动 IPTV-4gtv${RESET}"
    echo -e "${GREEN}2) 更新 IPTV-4gtv${RESET}"
    echo -e "${GREEN}3) 重启 IPTV-4gtv${RESET}"
    echo -e "${GREEN}4) 停止 IPTV-4gtv${RESET}"
    echo -e "${GREEN}5) 卸载 IPTV-4gtv${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) stop_app ;;
        5) uninstall_app ;;
        6) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择${RESET}" ;;
    esac
}

check_env
while true; do
    menu
    read -p "按回车键返回菜单..." enter
done
