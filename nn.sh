#!/bin/bash
# ======================================
# Melody 一键管理脚本 (端口映射模式)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="melody"
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
    echo -e "${GREEN}=== Melody 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/melody-profile"

    read -rp "请输入要绑定的端口 [默认 5566]: " port
    port=${port:-5566}

    cat > "$COMPOSE_FILE" <<EOF
services:
  melody:
    image: foamzou/melody:latest
    container_name: melody
    restart: unless-stopped
    ports:
      - "127.0.0.1:${port}:5566"
    volumes:
      - $APP_DIR/melody-profile:/app/backend/.profile
      - $APP_DIR/melody-profile:/app/melody-data
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ Melody 已启动${RESET}"
    echo -e "${YELLOW}本地访问地址: http://127.0.0.1:${port}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/melody-profile${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Melody 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Melody 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f melody
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
