#!/bin/bash
# ========================================
# FRP-Panel Master 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"
APP_NAME="frpp-master"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"


get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。"
}

function menu() {
    clear
    echo -e "${GREEN}=== FRP-Panel Master 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启服务${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR/data"

    read -p "请输入全局密钥 (APP_GLOBAL_SECRET) [留空自动生成]: " secret
    
    if [ -z "$secret" ]; then
        secret=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
        echo -e "已自动生成密钥: $secret"
    fi
    
    read -p "请输入服务器外网 IP/域名: " input_host
    SERVER_HOST=${input_host:-$(get_public_ip)}
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
    echo -e "${YELLOW}🌐 管理面板地址: http://$SERVER_HOST:$API_PORT${RESET}"
    echo -e "${YELLOW}🔑 全局密钥: $secret${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR/data${RESET}"
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

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${GREEN}正在重启 FRP-Panel Master...${RESET}"

    docker compose restart

    echo -e "${GREEN}✅ FRP-Panel Master 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f frpp-master
    read -p "按回车返回菜单..."
    menu
}

menu
