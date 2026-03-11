#!/bin/bash
# ========================================
# ech0 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ech0"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}Docker 未安装，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== ech0 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo

    read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR"

    read -p "请输入 ech0 端口 [默认:6277]: " input_port
    PORT=${input_port:-6277}

   read -p "请输入 JWT_SECRET [默认:自动生成]: " input_secret
   JWT_SECRET=${input_secret:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)}


    DATA_DIR=${input_data:-/opt/ech0/data}

    BACKUP_DIR=${input_backup:-/opt/ech0/backup}

    mkdir -p "$DATA_DIR"
    mkdir -p "$BACKUP_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  ech0:
    image: sn0wl1n/ech0:latest
    container_name: ech0
    restart: always
    ports:
      - "127.0.0.1:${PORT}:6277"
    volumes:
      - ${DATA_DIR}:/app/data
      - ${BACKUP_DIR}:/app/backup
    environment:
      - JWT_SECRET=${JWT_SECRET}
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ ech0 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}🔑 JWT_SECRET: ${JWT_SECRET}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${DATA_DIR}${RESET}"
    echo -e "${GREEN}📂 备份目录: ${BACKUP_DIR}${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ ech0 已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

restart_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose restart

    echo -e "${GREEN}✅ ech0 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

view_logs() {

    docker logs -f ech0

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {

    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }

    docker compose down
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ ech0 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

menu
