#!/bin/bash
# ======================================
# NapCat 一键管理脚本 (端口映射模式)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="napcat"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== napcat 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR/data" "$APP_DIR/config" "$APP_DIR/ntqq"

    read -rp "请输入要绑定的端口 [默认 6099]: " port
    port=${port:-6099}

    read -rp "请输入 UID [默认 1000]: " uid
    uid=${uid:-1000}

    read -rp "请输入 GID [默认 1000]: " gid
    gid=${gid:-1000}

    cat > "$COMPOSE_FILE" <<EOF
services:
  napcat:
    image: mlikiowa/napcat-docker:latest
    container_name: napcat
    restart: always
    environment:
      - NAPCAT_UID=${uid}
      - NAPCAT_GID=${gid}
      - MODE=astrbot
    ports:
      - "127.0.0.1:${port}:6099"
    volumes:
      - $APP_DIR/data:/AstrBot/data
      - $APP_DIR/config:/app/napcat/config
      - $APP_DIR/ntqq:/app/.config/QQ
    networks:
      - astrbot_network

networks:
  astrbot_network:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ NapCat 已启动${RESET}"
    echo -e "${YELLOW}本地访问端口: 127.0.0.1:${port}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ NapCat 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ NapCat 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f napcat
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
