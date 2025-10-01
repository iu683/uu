#!/bin/bash
# ======================================
# AstrBot 一键管理脚本 (端口映射模式)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="astrbot"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== AstrBot 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 卸载(含数据)${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 重启${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -rp "请选择: " choice
        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) uninstall_app ;;
            4) view_logs ;;
            5) restart_app ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

install_app() {
    mkdir -p "$APP_DIR/data"

    read -rp "请输入要绑定的主端口 [默认 6185]: " port
    port=${port:-6185}

    cat > "$COMPOSE_FILE" <<EOF
services:
  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: always
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "127.0.0.1:${port}:6185"
    volumes:
      - $APP_DIR/data:/AstrBot/data
    networks:
      - astrbot_network

networks:
  astrbot_network:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ AstrBot 已启动${RESET}"
    echo -e "${YELLOW}本地访问端口: 127.0.0.1:${port}${RESET}"
    echo -e "${GREEN}账号/密码: astrbot/astrbot${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; return; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ AstrBot 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ AstrBot 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    docker logs -f astrbot
    read -rp "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; return; }
    docker compose restart astrbot
    echo -e "${GREEN}✅ AstrBot 已重启完成${RESET}"
    read -rp "按回车返回菜单..."
}

check_docker
menu
