#!/bin/bash
# ========================================
# GOST Panel 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="gost-panel"
CONTAINER_NAME="gost-panel"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_env() {
    command -v docker >/dev/null 2>&1 || {
        echo -e "${RED}❌ 未检测到 Docker${RESET}"
        exit 1
    }

    docker compose version >/dev/null 2>&1 || {
        echo -e "${RED}❌ Docker Compose 不可用${RESET}"
        exit 1
    }
}

menu() {
    clear
    echo -e "${GREEN}=== GOST Panel 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) sleep 1; menu ;;
    esac
}

install_app() {

    if [ -f "$COMPOSE_FILE" ]; then
        read -p "已存在安装，是否覆盖重装？(y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && menu
    fi

    mkdir -p "$APP_DIR/data"

    read -p "Web 端口 [默认 8080]: " input_port
    PORT=${input_port:-8080}

    read -p "JWT_SECRET (留空自动生成更安全): " JWT_SECRET
    if [ -z "$JWT_SECRET" ]; then
        JWT_SECRET=$(openssl rand -hex 16)
        echo -e "${YELLOW}已自动生成 JWT_SECRET: $JWT_SECRET${RESET}"
    fi

    cat > "$COMPOSE_FILE" <<EOF

services:
  gost-panel:
    image: ghcr.io/alicenetworks/gost-panel:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    volumes:
      - "$APP_DIR/data:/app/data"
    environment:
      - JWT_SECRET=${JWT_SECRET}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ GOST Panel 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://服务器IP:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    echo -e "${YELLOW}Ctrl+C 返回菜单${RESET}"
    docker logs -f ${CONTAINER_NAME}
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { sleep 1; menu; }
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

check_env
menu
