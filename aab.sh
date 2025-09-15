#!/bin/bash
# QMediaSync 一键管理脚本

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="qmediasync"
YML_FILE="qmediasync-compose.yml"

CONFIG_DIR="/vol1/1000/docker/qmediasync/config"
MEDIA_DIR="/vol2/1000/网盘"

# 获取公网IP
get_ip() {
    curl -s ipv4.icanhazip.com || curl -s ifconfig.me
}

create_compose() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$MEDIA_DIR"

    cat > $YML_FILE <<EOF
version: "3.8"

services:
  qmediasync:
    image: qicfan/qmediasync:latest
    container_name: qmediasync
    restart: unless-stopped
    ports:
      - "12333:12333"
      - "8095:8095"
      - "8094:8094"
    volumes:
      - $CONFIG_DIR:/app/config
      - $MEDIA_DIR:/media
    environment:
      - TZ=Asia/Shanghai

networks:
  default:
    name: qmediasync
EOF
}

show_menu() {
    echo -e "${GREEN}=== QMediaSync 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装并启动 QMediaSync${RESET}"
    echo -e "${GREEN}2) 停止 QMediaSync${RESET}"
    echo -e "${GREEN}3) 启动 QMediaSync${RESET}"
    echo -e "${GREEN}4) 重启 QMediaSync${RESET}"
    echo -e "${GREEN}5) 更新 QMediaSync${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载 QMediaSync${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
}

print_access_info() {
    local ip=$(get_ip)
    echo -e "🌐 访问地址: ${GREEN}http://$ip:12333${RESET}"
    echo -e "👤 默认用户: ${GREEN}admin${RESET}"
    echo -e "🔑 默认密码: ${GREEN}admin123${RESET}"
}

install_app() {
    create_compose
    docker compose -f $YML_FILE up -d
    echo -e "✅ ${GREEN}QMediaSync 已安装并启动${RESET}"
    print_access_info
}

stop_app() {
    docker compose -f $YML_FILE down
    echo -e "🛑 ${GREEN}QMediaSync 已停止${RESET}"
}

start_app() {
    docker compose -f $YML_FILE up -d
    echo -e "🚀 ${GREEN}QMediaSync 已启动${RESET}"
    print_access_info
}

restart_app() {
    docker compose -f $YML_FILE down
    docker compose -f $YML_FILE up -d
    echo -e "🔄 ${GREEN}QMediaSync 已重启${RESET}"
    print_access_info
}

update_app() {
    docker compose -f $YML_FILE pull
    docker compose -f $YML_FILE up -d
    echo -e "⬆️ ${GREEN}QMediaSync 已更新到最新版本${RESET}"
    print_access_info
}

logs_app() {
    docker logs -f $APP_NAME
}

uninstall_app() {
    docker compose -f $YML_FILE down
    rm -f $YML_FILE
    echo -e "🗑️ ${GREEN}QMediaSync 已卸载 (数据目录保留在 $CONFIG_DIR 和 $MEDIA_DIR)${RESET}"
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
