#!/bin/bash
# ========================================
# 2FAuth 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="2fauth"
APP_DIR="/opt/$APP_NAME"
DATA_DIR="$APP_DIR/data"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

# ----------------- 菜单 -----------------
function menu() {
    clear
    echo -e "${GREEN}=== 2FAuth 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
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
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# ----------------- 安装 -----------------
function install_app() {
    read -p "请输入 Web 端口 [默认:8120]: " input_port
    PORT=${input_port:-8120}

    read -p "请输入 APP_KEY [默认:随机生成]: " input_key
    APP_KEY=${input_key:-$(openssl rand -hex 16)}

    read -p "请输入 APP_URL [例如:https://2fa.gugu.ovh]: " input_url
    APP_URL=${input_url:-https://2fa.gugu.ovh}

    # 创建数据目录并设置权限，避免 permission denied
    mkdir -p "$DATA_DIR"
    chown -R 1000:1000 "$DATA_DIR"
    chmod -R 755 "$DATA_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  2fauth:
    image: 2fauth/2fauth
    container_name: 2fauth
    volumes:
      - $DATA_DIR:/2fauth
    ports:
      - "127.0.0.1:$PORT:8000"
    environment:
      - APP_NAME=2FAuth
      - APP_KEY=$APP_KEY
      - APP_URL=$APP_URL
      - IS_DEMO_APP=false
      - LOG_CHANNEL=daily
      - LOG_LEVEL=notice
      - DB_DATABASE="/2fauth/database.sqlite"
      - CACHE_DRIVER=file
      - SESSION_DRIVER=file
      - AUTHENTICATION_GUARD=web-guard
    restart: unless-stopped
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"
    echo "APP_KEY=$APP_KEY" >> "$CONFIG_FILE"
    echo "APP_URL=$APP_URL" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ 2FAuth 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $DATA_DIR${RESET}"
    echo -e "${GREEN}🔑 APP_KEY: $APP_KEY${RESET}"
    echo -e "${GREEN}🔗 APP_URL: $APP_URL${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# ----------------- 更新 -----------------
function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 2FAuth 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# ----------------- 卸载 -----------------
function uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 吗？（这将删除所有数据）（y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker compose down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 2FAuth 已卸载，数据已删除${RESET}"
    else
        echo "❌ 已取消"
    fi
    read -p "按回车返回菜单..."
    menu
}

# ----------------- 查看日志 -----------------
function view_logs() {
    docker logs -f 2fauth
    read -p "按回车返回菜单..."
    menu
}

# ----------------- 启动菜单 -----------------
menu
