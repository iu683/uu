#!/bin/bash
# ========================================
# WeChat-Selkies 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="wechat-selkies"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

function menu() {
    clear
    echo -e "${GREEN}=== WeChat-Selkies 管理菜单 ===${RESET}"
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

function install_app() {
    mkdir -p "$APP_DIR/config"

    read -p "请输入 Web 端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}

    read -p "请输入 Web 登录用户名 [默认:admin]: " input_user
    CUSTOM_USER=${input_user:-admin}

    read -p "请输入 Web 登录密码 [默认:changeme]: " input_pass
    PASSWORD=${input_pass:-changeme}

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  wechat-selkies:
    image: ghcr.io/nickrunning/wechat-selkies:latest
    container_name: wechat-selkies
    stdin_open: true
    tty: true
    restart: unless-stopped
    ports:
      - "127.0.0.1:\${PORT}:3001"
    environment:
      - PUID=1000
      - PGID=100
      - TZ=Asia/Shanghai
      - CUSTOM_USER=\${CUSTOM_USER}
      - PASSWORD=\${PASSWORD}
    volumes:
      - ./config:/config
EOF

    cd "$APP_DIR"
    export PORT CUSTOM_USER PASSWORD
    docker compose up -d

    echo -e "${GREEN}✅ WeChat-Selkies 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}👤 用户名: $CUSTOM_USER${RESET}"
    echo -e "${GREEN}🔑 密码: $PASSWORD${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ WeChat-Selkies 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ WeChat-Selkies 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f wechat-selkies
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ WeChat-Selkies 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
