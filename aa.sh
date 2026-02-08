#!/bin/bash
# ========================================
# MoonTVPlus 一键管理脚本 (Docker Compose)
# 双容器版：core + kvrocks
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="moontvplus"
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
    echo -e "${GREEN}=== MoonTVPlus 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/kvrocks-data"

    read -p "Web 端口 [默认 3000]: " input_port
    PORT=${input_port:-3000}

    read -p "管理员用户名 [默认 admin]: " USERNAME
    USERNAME=${USERNAME:-admin}

    read -p "管理员密码 [默认 admin_password]: " PASSWORD
    PASSWORD=${PASSWORD:-admin_password}

    cat > "$COMPOSE_FILE" <<EOF
version: "3"

services:
  moontv-core:
    image: ghcr.io/mtvpls/moontvplus:latest
    container_name: moontv-core
    restart: on-failure
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://moontv-kvrocks:6666
    depends_on:
      - moontv-kvrocks
    networks:
      - moontv-network

  moontv-kvrocks:
    image: apache/kvrocks
    container_name: moontv-kvrocks
    restart: unless-stopped
    volumes:
      - "$APP_DIR/kvrocks-data:/var/lib/kvrocks"
    networks:
      - moontv-network

networks:
  moontv-network:
    driver: bridge
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ MoonTVPlus 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 KV 数据目录: $APP_DIR/kvrocks-data${RESET}"

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
    docker compose logs -f
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
