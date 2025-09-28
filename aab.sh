#!/bin/bash
# ========================================
# AllinSSL 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="allinssl"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== AllinSSL 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入宿主机端口 [默认:7979]: " input_port
    PORT=${input_port:-7979}

    read -p "请输入管理员用户名 [默认:allinssl]: " input_user
    USERNAME=${input_user:-allinssl}

    read -p "请输入管理员密码 [默认:allinssldocker]: " input_pwd
    PASSWORD=${input_pwd:-allinssldocker}

    mkdir -p "$APP_DIR/data"

    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  allinssl:
    image: allinssl/allinssl:latest
    container_name: allinssl
    restart: unless-stopped
    ports:
      - "$PORT:8888"
    environment:
      - ALLINSSL_USER=$USERNAME
      - ALLINSSL_PWD=$PASSWORD
      - ALLINSSL_URL=allinssl
    volumes:
      - $APP_DIR/data:/www/allinssl/data
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "ALLINSSL_USER=$USERNAME" >> "$CONFIG_FILE"
    echo "ALLINSSL_PWD=$PASSWORD" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d


# 获取本机IP
    get_ip() {
        curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1"
    }

    echo -e "${GREEN}✅ AllinSSL 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🔑 管理员账号: $USERNAME  密码: $PASSWORD${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ AllinSSL 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ AllinSSL 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f allinssl
    read -p "按回车返回菜单..."
    menu
}

menu
