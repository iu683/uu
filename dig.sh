#!/bin/bash
# ========================================
# XTrafficDash 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="xtrafficdash"
COMPOSE_DIR="/usr/xtrafficdash"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DEFAULT_PORT=37022
DEFAULT_PASSWORD="admin123"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== xtrafficdash 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) show_password ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:${DEFAULT_PORT}]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    read -p "请输入管理员密码 [默认:${DEFAULT_PASSWORD}]: " input_pass
    PASSWORD=${input_pass:-$DEFAULT_PASSWORD}

    mkdir -p "$COMPOSE_DIR/data"
    chmod 777 "$COMPOSE_DIR/data"

    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  xtrafficdash:
    image: sanqi37/xtrafficdash
    container_name: xtrafficdash
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:37022"
    environment:
      - TZ=Asia/Shanghai
      - DATABASE_PATH=/app/data/xtrafficdash.db
      - PASSWORD=${PASSWORD}
    volumes:
      - ${COMPOSE_DIR}/data:/app/data
    logging:
      options:
        max-size: "5m"
        max-file: "3"
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $COMPOSE_DIR/data${RESET}"
    echo -e "${GREEN}🔑 管理员密码: $PASSWORD${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ${APP_NAME} 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose down -v
    rm -rf "$COMPOSE_DIR"
    echo -e "${GREEN}✅ ${APP_NAME} 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f xtrafficdash
    read -p "按回车返回菜单..."
    menu
}


menu
