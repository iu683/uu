#!/bin/bash
# ========================================
# MHTI 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mhti"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== MHTI 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    read -p "请输入 Web 端口 [默认:8000]: " input_port
    PORT=${input_port:-8000}

    read -p "请输入 媒体库路径: " MEDIA_DIR
    read -p "请输入 输出目录路径: " OUTPUT_DIR

    mkdir -p "$APP_DIR/data" "$OUTPUT_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  mhti:
    image: xiyan520/mhti:latest
    container_name: mhti
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8000"
    volumes:
      - ./data:/app/data
      - \${MEDIA_DIR}:/media:ro
      - \${OUTPUT_DIR}:/output
    environment:
      - TZ=Asia/Shanghai
      - DATA_DIR=/app/data
EOF

    cd "$APP_DIR" || exit
    PORT=$PORT \
    MEDIA_DIR=$MEDIA_DIR \
    OUTPUT_DIR=$OUTPUT_DIR \
    docker compose up -d

    echo -e "${GREEN}✅ MHTI 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🎞 媒体目录: $MEDIA_DIR${RESET}"
    echo -e "${GREEN}📤 输出目录: $OUTPUT_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MHTI 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ MHTI 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f mhti
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MHTI 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
