#!/bin/bash
# ========================================
# Stb图床 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="stb"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

# 获取宿主机 IP
function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
}

# 菜单
function menu() {
    clear
    echo -e "${GREEN}=== Stb图床 管理菜单 ===${RESET}"
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

# 安装/启动
function install_app() {
    read -p "请输入宿主机端口 [默认:25519]: " input_port
    PORT=${input_port:-25519}

    mkdir -p "$APP_DIR/uploads"

    # 自动生成 JWT_SECRET
    if [ ! -f "$ENV_FILE" ]; then
        JWT_SECRET=$(openssl rand -hex 16)
        cat > "$ENV_FILE" <<EOF
JWT_SECRET=$JWT_SECRET
PORT=$PORT
VITE_APP_TITLE=Stb图床
EOF
    else
        source "$ENV_FILE"
    fi

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - '$PORT:25519'
    volumes:
      - uploads_volume:/app/server/uploads
      - $APP_DIR/.env:/app/server/.env
    depends_on:
      mongodb:
        condition: service_healthy
    networks:
      - app-network
    restart: unless-stopped
    environment:
      - PORT=25519
      - MONGODB_URI=mongodb://mongodb:27017/stb
      - JWT_SECRET=$JWT_SECRET
      - VITE_APP_TITLE=Stb图床

  mongodb:
    image: mongo:latest
    ports:
      - '27017:27017'
    volumes:
      - mongodb_data:/data/db
    networks:
      - app-network
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.runCommand({ ping: 1 })"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped
    container_name: mongodb

networks:
  app-network:
    driver: bridge

volumes:
  mongodb_data:
  uploads_volume:
EOF

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Stb图床 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://$(get_ip):$PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/uploads${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 更新
function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Stb图床 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 卸载
function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Stb图床 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

# 查看日志
function view_logs() {
    docker logs -f app
    read -p "按回车返回菜单..."
    menu
}

menu
