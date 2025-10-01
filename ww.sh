#!/bin/bash
# ========================================
# SPlayer 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="SPlayer"
APP_DIR="/opt/splayer"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# ================== 主菜单 ==================
menu() {
    clear
    echo -e "${GREEN}===== SPlayer 管理菜单 =====${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请输入编号: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}"; sleep 1; menu ;;
    esac
}

# ================== 安装 ==================
install_app() {
    read -rp "请输入访问端口 [默认:25884]: " input_port
    PORT=${input_port:-25884}

    mkdir -p "$APP_DIR/config" "$APP_DIR/data"

    cat > "$COMPOSE_FILE" <<EOF

services:
  splayer:
    container_name: splayer
    image: imsyy/splayer:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:25884"
    volumes:
      - ./config:/app/config
      - ./data:/app/data
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

# ================== 更新 ==================
update_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录，请先安装${RESET}"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ $APP_NAME 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

# ================== 卸载 ==================
uninstall_app() {
    cd "$APP_DIR" || { echo -e "${RED}未检测到安装目录${RESET}"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ $APP_NAME 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

# ================== 日志 ==================
view_logs() {
    docker logs -f splayer
    read -rp "按回车返回菜单..."
    menu
}

menu
