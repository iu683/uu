#!/bin/bash
# ========================================
# Vertex 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="vertex"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Vertex 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    mkdir -p "$APP_DIR/config"

    cat > "$COMPOSE_FILE" <<EOF
services:
  vertex:
    image: lswl/vertex:stable
    container_name: vertex
    restart: unless-stopped
    network_mode: bridge
    environment:
      - TZ=Asia/Shanghai
      - PORT=3000
    ports:
      - "127.0.0.1:$PORT:3000"
    volumes:
      - $APP_DIR/config:/vertex
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Vertex 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Vertex 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Vertex 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f vertex
    read -p "按回车返回菜单..."
    menu
}

# 查看初始密码（分页显示）
show_password() {
    PASSWORD_FILE="/root/vertex/config/data/password"
    if [ -f "$PASSWORD_FILE" ]; then
        echo -e "\033[32m初始密码内容:\033[0m"
        more "$PASSWORD_FILE"
    else
        echo -e "\033[32m未找到初始密码文件\033[0m"
    fi
    read -p "按回车返回菜单..."
    menu
}


menu
