#!/bin/bash
# ========================================
# Nginx Proxy Manager 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="nginx-proxy-manager"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 获取公网 IP
get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== Nginx Proxy Manager 管理菜单 ===${RESET}"
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

function install_app() {
    # 自定义管理端口，默认 81
    read -p "请输入 管理端口 [默认:81]: " input_admin
    ADMIN_PORT=${input_admin:-81}

    # 创建统一文件夹
    mkdir -p "$APP_DIR/data" "$APP_DIR/letsencrypt"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'       # HTTP 固定
      - '${ADMIN_PORT}:81'  # 管理端口可自定义
      - '443:443'     # HTTPS 固定
    volumes:
      - $APP_DIR/data:/data
      - $APP_DIR/letsencrypt:/etc/letsencrypt
EOF

    # 保存配置
    echo "ADMIN_PORT=$ADMIN_PORT" > "$CONFIG_FILE"

    # 启动容器
    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Nginx Proxy Manager 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$ADMIN_PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}🔐 Let's Encrypt 目录: $APP_DIR/letsencrypt${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Nginx Proxy Manager 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Nginx Proxy Manager 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f app
    read -p "按回车返回菜单..."
    menu
}

menu
