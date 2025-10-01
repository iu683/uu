#!/bin/bash
# ========================================
# FRP-Panel Master 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="frpp-master"
APP_DIR="/opt/frp/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== FRP-Panel Master 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
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
    mkdir -p "$APP_DIR/data"

    read -p "请输入全局密钥 (APP_GLOBAL_SECRET): " secret
    SERVER_HOST="127.0.0.1"
    echo "管理面板绑定地址固定为: $SERVER_HOST"

    read -p "请输入 RPC 端口 [默认:9001]: " input_rpc
    RPC_PORT=${input_rpc:-9001}
    read -p "请输入 API 端口 [默认:9000]: " input_api
    API_PORT=${input_api:-9000}

    # 写入 env
    cat > "$CONFIG_FILE" <<EOF
APP_GLOBAL_SECRET=$secret
SERVER_HOST=$SERVER_HOST
RPC_PORT=$RPC_PORT
API_PORT=$API_PORT
EOF

    # 写 compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  frpp-master:
    image: vaalacat/frp-panel:latest
    container_name: frpp-master
    network_mode: host
    environment:
      APP_GLOBAL_SECRET: $secret
      MASTER_RPC_HOST: $SERVER_HOST
      MASTER_RPC_PORT: $RPC_PORT
      MASTER_API_HOST: $SERVER_HOST
      MASTER_API_PORT: $API_PORT
      MASTER_API_SCHEME: http
    volumes:
      - $APP_DIR/data:/data
    restart: unless-stopped
    command: master
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ FRP-Panel Master 已启动${RESET}"
    echo -e "${GREEN}🌐 管理面板地址: http://$SERVER_HOST:$API_PORT${RESET}"
    echo -e "${GREEN}🔑 全局密钥: $secret${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ FRP-Panel Master 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ FRP-Panel Master 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f frpp-master
    read -p "按回车返回菜单..."
    menu
}

menu
