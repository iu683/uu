#!/bin/bash
# ========================================
# Glash (Clash/Mihomo) 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="glash"
CONTAINER_NAME="glash"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_env() {
    command -v docker >/dev/null 2>&1 || {
        echo -e "${RED}❌ 未检测到 Docker${RESET}"
        exit 1
    }
}

menu() {
    clear
    echo -e "${GREEN}=== Glash 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含配置)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

install_app() {

    mkdir -p "$APP_DIR/config"

    read -p "HTTP 端口 [默认 7890]: " p1
    read -p "SOCKS5 端口 [默认 7891]: " p2
    read -p "Dashboard 端口 [默认 9090]: " p3
    read -p "订阅地址 SUB_URL: " SUB_URL
    read -p "订阅更新周期(cron) [默认 0 */6 * * *]: " CRON
    read -p "Dashboard 密码 SECRET (留空自动生成): " SECRET

    PORT1=${p1:-7890}
    PORT2=${p2:-7891}
    PORT3=${p3:-9090}
    CRON=${CRON:-"0 */6 * * *"}

    if [ -z "$SECRET" ]; then
        SECRET=$(openssl rand -hex 8)
        echo -e "${YELLOW}已自动生成 SECRET: $SECRET${RESET}"
    fi

    cat > "$COMPOSE_FILE" <<EOF

services:
  glash:
    image: gangz1o/glash:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PORT1}:7890"
      - "${PORT2}:7891"
      - "${PORT3}:9090"
    volumes:
      - "$APP_DIR/config:/root/.config/mihomo"
    environment:
      - TZ=Asia/Shanghai
      - SUB_URL=${SUB_URL}
      - SUB_CRON=${CRON}
      - SECRET=${SECRET}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ Glash 已启动${RESET}"
    echo -e "${YELLOW}HTTP 代理:   服务器IP:${PORT1}${RESET}"
    echo -e "${YELLOW}SOCKS5 代理: 服务器IP:${PORT2}${RESET}"
    echo -e "${YELLOW}Dashboard:   http://服务器IP:${PORT3}${RESET}"
    echo -e "${GREEN}密码: $SECRET${RESET}"
    echo -e "${GREEN}配置目录: $APP_DIR/config${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 已更新完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || { menu; }
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f ${CONTAINER_NAME}
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { menu; }
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载（含配置）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

check_env
menu
