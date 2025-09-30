#!/bin/bash
# ======================================
# NodePass Dashboard 一键管理脚本 (端口映射模式)
# ======================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nodepassdash"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

check_wget() {
    if ! command -v wget &>/dev/null; then
        echo -e "${GREEN}未检测到 wget，正在安装...${RESET}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y wget
        elif command -v yum &>/dev/null; then
            yum install -y wget
        elif command -v dnf &>/dev/null; then
            dnf install -y wget
        elif command -v apk &>/dev/null; then
            apk add --no-cache wget
        else
            echo -e "${RED}无法自动安装 wget，请手动安装后重试${RESET}"
            exit 1
        fi
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== NodePass Dashboard 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
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
    mkdir -p "$APP_DIR/config" "$APP_DIR/public"

    read -rp "请输入 Web 端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  nodepassdash:
    image: ghcr.io/nodepassproject/nodepassdash:latest
    container_name: nodepassdash
    ports:
      - "127.0.0.1:\${PORT}:3000"
    volumes:
      - ./config:/app/config:ro
      - ./public:/app/public
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ NodePass Dashboard 已启动${RESET}"
    echo -e "${GREEN}🌐 Web 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ NodePass Dashboard 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ NodePass Dashboard 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f nodepassdash
    read -rp "按回车返回菜单..."
    menu
}

check_docker
check_wget
menu
