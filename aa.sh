#!/bin/bash
# ========================================
# EasyImg 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="easyimg"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== EasyImg 管理菜单 ===${RESET}"
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
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR"/{db,uploads}

    read -p "请输入 Web 端口 [默认:8092]: " input_port
    PORT=${input_port:-8092}

    cat > "$COMPOSE_FILE" <<EOF
services:
  easyimg:
    image: ghcr.io/chaos-zhu/easyimg:latest
    container_name: easyimg
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - /opt/easyimg/db:/app/db
      - /opt/easyimg/uploads:/app/uploads
    environment:
      - NODE_ENV=production
      - PORT=3000
EOF

    cd "$APP_DIR" || exit
    PORT=$PORT docker compose up -d

    echo -e "${GREEN}✅ EasyImg 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/db${RESET}"
    echo -e "${GREEN}📂 上传目录: $APP_DIR/uploads${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ EasyImg 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ EasyImg 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f easyimg
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ EasyImg 已卸载（数据已删除）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
