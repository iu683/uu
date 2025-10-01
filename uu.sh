#!/bin/bash
# ======================================
# Looking-Glass Server 一键管理脚本
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="looking-glass"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 获取公网 IP
get_public_ip() {
    ip=$(curl -s https://api64.ipify.org || wget -qO- https://api64.ipify.org)
    echo "$ip"
}

menu() {
    clear
    echo -e "${GREEN}=== looking-glass 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    read -rp "请输入 HTTP 端口 [默认 8080]: " port
    port=${port:-8080}

    cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}:
    image: wikihostinc/looking-glass-server:latest
    container_name: ${APP_NAME}
    restart: always
    environment:
      - HTTP_PORT=8080
    ports:
      - "0.0.0.0:${port}:8080"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    public_ip=$(get_public_ip)
    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${YELLOW}访问地址: http://${public_ip}:${port}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ${APP_NAME} 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ ${APP_NAME} 已卸载${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f ${APP_NAME}
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
