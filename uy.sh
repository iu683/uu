#!/bin/bash
# ========================================
# X-UI 一键管理脚本 (Docker Compose + host 网络)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="3x-ui"
APP_DIR="/opt/docker/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== 3X-UI 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}======================${RESET}"
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
    read -p "请输入 Web 端口[默认:54321]: " input_port
    PORT=${input_port:-54321}

    mkdir -p "$APP_DIR/3x-ui" "$APP_DIR/acme.sh"

    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  3x-ui:
    image: aircross/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped
    network_mode: host
    environment:
      - XRAY_VMESS_AEAD_FORCED=false
    volumes:
      - $APP_DIR/3x-ui/:/etc/x-ui/
      - $APP_DIR/acme.sh/:/root/cert/
EOF

    echo "PORT=$PORT" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    # 获取公网 IP
    get_ip() {
        curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "0.0.0.0"
    }

    echo -e "${GREEN}✅ 3X-UI 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/3x-ui${RESET}"
    echo -e "${GREEN}📂 证书目录: $APP_DIR/acme.sh${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    source "$CONFIG_FILE"
    echo -e "${GREEN}✅ 3X-UI 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ 3X-UI 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f 3x-ui
    read -p "按回车返回菜单..."
    menu
}

menu
