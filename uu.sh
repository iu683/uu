#!/bin/bash
# ========================================
# FRP-Panel Client 一键管理脚本
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="frp-panel-client"
APP_DIR="/opt/frp/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== FRP-Panel Client 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    read -p "请输入全局密钥 (需与 Master 相同): " secret
    read -p "请输入客户端 ID [默认: client1]: " input_id
    CLIENT_ID=${input_id:-client1}
    read -p "请输入 Master API 地址 [默认: https://frpp.example.com:443]: " input_api
    API_URL=${input_api:-https://frpp.example.com:443}
    read -p "请输入 Master RPC 地址 [默认: wss://frpp.example.com:443]: " input_rpc
    RPC_URL=${input_rpc:-wss://frpp.example.com:443}

    cat > "$CONFIG_FILE" <<EOF
SECRET=$secret
CLIENT_ID=$CLIENT_ID
API_URL=$API_URL
RPC_URL=$RPC_URL
EOF

    cat > "$COMPOSE_FILE" <<EOF

services:
  frp-panel-client:
    image: vaalacat/frp-panel:latest
    container_name: frp-panel-client
    network_mode: host
    restart: unless-stopped
    command: client -s $secret -i $CLIENT_ID --api-url $API_URL --rpc-url $RPC_URL
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ FRP-Panel Client 已启动${RESET}"
    echo -e "${GREEN}🆔 客户端ID: $CLIENT_ID${RESET}"
    echo -e "${GREEN}🔑 密钥: $secret${RESET}"
    echo -e "${GREEN}🌐 Master API: $API_URL${RESET}"
    echo -e "${GREEN}🌐 Master RPC: $RPC_URL${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ FRP-Panel Client 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ FRP-Panel Client 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f frp-panel-client
    read -p "按回车返回菜单..."
    menu
}

menu
