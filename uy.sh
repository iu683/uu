#!/bin/bash
# ========================================
# Vertex 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="vertex"
COMPOSE_DIR="$HOME/vertex"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DEFAULT_PORT=3000

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function menu() {
    clear
    echo -e "${GREEN}=== vertex 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 查看初始密码${RESET}"
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

    mkdir -p "$COMPOSE_DIR"

    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  vertex:
    image: lswl/vertex:stable
    container_name: vertex
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
    volumes:
      - ${COMPOSE_DIR}:/vertex
    environment:
      - TZ=Asia/Shanghai
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $COMPOSE_DIR${RESET}"
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
    docker logs -f vertex
    read -p "按回车返回菜单..."
    menu
}

# 查看初始密码
function show_password() {
    if [ -f "$COMPOSE_DIR/data/password" ]; then
        echo -e "${GREEN}初始密码如下:${RESET}"
        more "$COMPOSE_DIR/data/password"
    else
        echo -e "${GREEN}⚠️  未找到密码文件: $COMPOSE_DIR/data/password${RESET}"
    fi
    read -p "按回车返回菜单..."
    menu
}

menu
