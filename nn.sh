#!/bin/bash
# ========================================
# Kavita 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="kavita"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== Kavita 管理菜单 ===${RESET}"
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

    read -p "请输入 Web 端口 [默认:5000]: " input_port
    PORT=${input_port:-5000}

    read -p "请输入 Manga 目录路径: " MANGA_DIR
    read -p "请输入 Comics 目录路径: " COMICS_DIR
    read -p "请输入 Books 目录路径: " BOOKS_DIR

    read -p "请输入 配置目录路径 [/opt/kavita/config]: " input_config
    CONFIG_DIR=${input_config:-$APP_DIR/config}

    read -p "请输入 时区 [Asia/Shanghai]: " input_tz
    TZ=${input_tz:-Asia/Shanghai}

    mkdir -p "$CONFIG_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  kavita:
    image: jvmilazz0/kavita:latest
    container_name: kavita
    volumes:
      - \${MANGA_DIR}:/manga
      - \${COMICS_DIR}:/comics
      - \${BOOKS_DIR}:/books
      - \${CONFIG_DIR}:/kavita/config
    environment:
      - TZ=\${TZ}
    ports:
      - "127.0.0.1:${PORT}:5000"
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    PORT=$PORT \
    MANGA_DIR=$MANGA_DIR \
    COMICS_DIR=$COMICS_DIR \
    BOOKS_DIR=$BOOKS_DIR \
    CONFIG_DIR=$CONFIG_DIR \
    TZ=$TZ \
    docker compose up -d

    echo -e "${GREEN}✅ Kavita 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 Manga: $MANGA_DIR${RESET}"
    echo -e "${GREEN}📂 Comics: $COMICS_DIR${RESET}"
    echo -e "${GREEN}📂 Books: $BOOKS_DIR${RESET}"
    echo -e "${GREEN}📂 Config: $CONFIG_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Kavita 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Kavita 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f kavita
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Kavita 已卸载（包含配置数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
