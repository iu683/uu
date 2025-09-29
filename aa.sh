#!/bin/bash
# ========================================
# Nexus Terminal 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="nexus-terminal"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Nexus Terminal 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
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
    read -p "请输入前端宿主机端口 [默认:18111]: " input_front
    PORT_FRONT=${input_front:-18111}

    read -p "请输入后端宿主机端口 [默认:3001]: " input_back
    PORT_BACK=${input_back:-3001}

    read -p "请输入远程网关 HTTP 端口 [默认:9090]: " input_gateway_http
    PORT_GATEWAY_HTTP=${input_gateway_http:-9090}

    read -p "请输入远程网关 WS 端口 [默认:8080]: " input_gateway_ws
    PORT_GATEWAY_WS=${input_gateway_ws:-8080}

    mkdir -p "$APP_DIR/data"

    cat > "$COMPOSE_FILE" <<EOF

services:
  frontend:
    image: heavrnl/nexus-terminal-frontend:latest
    container_name: nexus-terminal-frontend
    ports:
      - "127.0.0.1:$PORT_FRONT:80"
    depends_on:
      - backend
      - remote-gateway

  backend:
    image: heavrnl/nexus-terminal-backend:latest
    container_name: nexus-terminal-backend
    environment:
      NODE_ENV: production
      PORT: 3001
      DEPLOYMENT_MODE: docker
      REMOTE_GATEWAY_API_BASE_LOCAL: http://localhost:$PORT_GATEWAY_HTTP
      REMOTE_GATEWAY_API_BASE_DOCKER: http://remote-gateway:$PORT_GATEWAY_HTTP
      REMOTE_GATEWAY_WS_URL_DOCKER: ws://remote-gateway:$PORT_GATEWAY_WS
      RP_ID: localhost
      RP_ORIGIN: http://localhost
    ports:
      - "127.0.0.1:$PORT_BACK:3001"
    volumes:
      - $APP_DIR/data:/app/data  

  remote-gateway:
    image: heavrnl/nexus-terminal-remote-gateway:latest
    container_name: nexus-terminal-remote-gateway
    environment:
      GUACD_HOST: guacd
      GUACD_PORT: 4822
      REMOTE_GATEWAY_API_PORT: $PORT_GATEWAY_HTTP
      REMOTE_GATEWAY_WS_PORT: $PORT_GATEWAY_WS
      FRONTEND_URL: http://frontend
      MAIN_BACKEND_URL: http://backend:3001
      NODE_ENV: production
    ports:
      - "127.0.0.1:$PORT_GATEWAY_HTTP:$PORT_GATEWAY_HTTP"
      - "127.0.0.1:$PORT_GATEWAY_WS:$PORT_GATEWAY_WS"
    depends_on:
      - guacd
      - backend  

  guacd:
    image: guacamole/guacd:latest
    container_name: nexus-terminal-guacd
    restart: unless-stopped
EOF

    echo "PORT_FRONT=$PORT_FRONT" > "$CONFIG_FILE"
    echo "PORT_BACK=$PORT_BACK" >> "$CONFIG_FILE"
    echo "PORT_GATEWAY_HTTP=$PORT_GATEWAY_HTTP" >> "$CONFIG_FILE"
    echo "PORT_GATEWAY_WS=$PORT_GATEWAY_WS" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    # 获取公网 IP
    get_ip() {
        curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
    }

    echo -e "${GREEN}✅ Nexus Terminal 已启动${RESET}"
    echo -e "${GREEN}🌐 前端 Web UI 地址: http://127.0.0.1:$PORT_FRONT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}⚙️ 后端端口: $PORT_BACK, 远程网关 HTTP: $PORT_GATEWAY_HTTP, WS: $PORT_GATEWAY_WS${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Nexus Terminal 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Nexus Terminal 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f nexus-terminal-frontend
    read -p "按回车返回菜单..."
    menu
}

menu
