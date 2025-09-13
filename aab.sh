#!/bin/bash
# ============================================
# IPTV-4gtv 一键管理脚本
# 功能: 安装/更新/卸载/查看日志
# ============================================

APP_NAME="iptv-4gtv"
IMAGE_NAME="instituteiptv/iptv-4gtv:latest"
CONFIG_FILE="./iptv-4gtv.conf"

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
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
PORT="$PORT"
EOF
}

install_app() {
    load_config

    read -p "请输入映射端口 (默认 ${PORT:-50017}): " input
    PORT=${input:-${PORT:-50017}}

    save_config

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME ...${RESET}"

    docker run -d \
      --name=$APP_NAME \
      -p ${PORT}:5050 \
      --restart=always \
      $IMAGE_NAME

    SERVER_IP=$(get_ip)

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${GREEN}📺 订阅地址: http://${SERVER_IP}:${PORT}/?type=m3u${RESET}"
}

update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
    echo -e "${GREEN}✅ 容器已更新并启动${RESET}"
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 并删除配置吗？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker stop $APP_NAME && docker rm $APP_NAME
        rm -f $CONFIG_FILE
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
    echo -e "${GREEN}=== IPTV-4gtv 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 IPTV-4gtv${RESET}"
    echo -e "${GREEN}2) 更新 IPTV-4gtv${RESET}"
    echo -e "${GREEN}3) 卸载 IPTV-4gtv${RESET}"
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
