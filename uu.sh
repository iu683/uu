#!/bin/bash
# ========================================
# Stb 图床 一键管理脚本（Docker Compose + 自动生成 JWT_SECRET）
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="Stb图床"
COMPOSE_DIR="$HOME/stb"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
DEFAULT_PORT=25519

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

function generate_jwt_secret() {
    openssl rand -base64 32
}

function menu() {
    clear
    echo -e "${GREEN}=== Stb图床 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动=${RESET}"
    echo -e "${GREEN}2) 更新=${RESET}"
    echo -e "${GREEN}3) 卸载 (含数据)=${RESET}"
    echo -e "${GREEN}4) 查看日志=${RESET}"
    echo -e "${GREEN}0) 退出=${RESET}"
    echo -e "${GREEN}========================${RESET}"
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
    read -p "请输入 Web 端口 [默认:${DEFAULT_PORT}]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    mkdir -p "$COMPOSE_DIR/uploads" "$COMPOSE_DIR/mongodb_data"

    # 生成 JWT_SECRET 并写入 .env
    JWT_SECRET=$(generate_jwt_secret)
    cat > "$ENV_FILE" <<EOF
PORT=${PORT}
JWT_SECRET=${JWT_SECRET}
EOF

    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'

services:
  app:
    image: yourusername/stb-app:latest
    container_name: stb-app
    restart: unless-stopped
    ports:
      - "\${PORT}:\${PORT}"
    volumes:
      - ${COMPOSE_DIR}/uploads:/app/server/uploads
      - ${ENV_FILE}:/app/server/.env
    environment:
      - PORT=\${PORT}
      - MONGODB_URI=mongodb://mongodb:27017/stb
      - JWT_SECRET=\${JWT_SECRET}
      - VITE_APP_TITLE=Stb图床

  mongodb:
    image: mongo:latest
    container_name: mongodb
    restart: unless-stopped
    ports:
      - "27017:27017"
    volumes:
      - ${COMPOSE_DIR}/mongodb_data:/data/db
EOF

    cd "$COMPOSE_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $COMPOSE_DIR${RESET}"
    echo -e "${GREEN}🔑 JWT_SECRET: $JWT_SECRET${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$COMPOSE_DIR" || exit
    docker compose pull
    docker compose up -d
    source "$ENV_FILE"
    echo -e "${GREEN}✅ ${APP_NAME} 已更新并重启完成${RESET}"
    echo -e "${GREEN}🔑 当前 JWT_SECRET: $JWT_SECRET${RESET}"
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
    docker logs -f stb-app
    read -p "按回车返回菜单..."
    menu
}

menu
