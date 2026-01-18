#!/bin/bash
# ========================================
# Ani-RSS 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="ani-rss"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

menu() {
    clear
    echo -e "${GREEN}=== Ani-RSS 管理菜单 ===${RESET}"
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

    read -p "请输入 Ani-RSS 端口 [默认:7789]: " input_port
    PORT=${input_port:-7789}

    read -p "请输入配置目录 [默认:/opt/ani-rss/config]: " input_config
    CONFIG_DIR=${input_config:-/opt/ani-rss/config}

    read -p "请输入媒体目录 [默认:/opt/ani-rss/Media]: " input_media
    MEDIA_DIR=${input_media:-/opt/ani-rss/Media}

    mkdir -p "$CONFIG_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  ani-rss:
    image: wushuo894/ani-rss
    container_name: ani-rss
    restart: always
    ports:
      - "127.0.0.1:${PORT}:7789"
    volumes:
      - ${CONFIG_DIR}:/config
      - ${MEDIA_DIR}:/Media
    environment:
      - PORT=7789
      - CONFIG=/config
      - TZ=Asia/Shanghai
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ Ani-RSS 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 配置目录: ${CONFIG_DIR}${RESET}"
    echo -e "${GREEN}📂 媒体目录: ${MEDIA_DIR}${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Ani-RSS 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Ani-RSS 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f ani-rss
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Ani-RSS 已卸载（配置与媒体目录未删除）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
