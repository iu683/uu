#!/bin/bash
# ======================================
# Stb 图床 一键管理脚本 (Docker 官方镜像)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="stb"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
IMAGE_NAME="setube/stb:latest"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== Stb 图床管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR/uploads"
    mkdir -p "$APP_DIR/server"
    chown -R 1000:1000 "$APP_DIR"
    chmod -R 755 "$APP_DIR"

    read -rp "请输入 Web 端口 [默认:25519]: " APP_PORT
    APP_PORT=${APP_PORT:-25519}

    # 随机生成 JWT_SECRET
    JWT_SECRET=$(openssl rand -hex 32)

    # 写入 .env 文件
    cat > "$ENV_FILE" <<EOF
JWT_SECRET=${JWT_SECRET}
PORT=${APP_PORT}
MONGODB_URI=mongodb://mongodb:27017/stb
VITE_APP_TITLE=Stb图床
EOF

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF


services:
  app:
    image: ${IMAGE_NAME}
    container_name: stb_app
    ports:
      - "127.0.0.1:${APP_PORT}:25519"
    volumes:
      - uploads_volume:/app/server/uploads
      - ./server/.env:/app/server/.env:ro
    depends_on:
      - mongodb
    networks:
      - app-network
    restart: unless-stopped
    environment:
      - PORT=25519
      - MONGODB_URI=mongodb://mongodb:27017/stb
      - JWT_SECRET=${JWT_SECRET}
      - VITE_APP_TITLE=Stb图床
    expose:
      - 25519

  mongodb:
    image: mongo:6.0
    container_name: mongodb
    ports:
      - "27017:27017"
    volumes:
      - mongodb_data:/data/db
    networks:
      - app-network
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.runCommand({ ping: 1 })"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

networks:
  app-network:
    driver: bridge

volumes:
  mongodb_data:
  uploads_volume:
EOF

    # 拉取官方镜像并启动
    echo -e "${YELLOW}📦 拉取官方镜像并启动容器...${RESET}"
    docker compose up -d

    echo -e "${GREEN}✅ Stb 图床已启动${RESET}"
    echo -e "${YELLOW}本地访问地址: http://127.0.0.1:${APP_PORT}${RESET}"
    echo -e "${GREEN}JWT_SECRET: ${JWT_SECRET}${RESET}"
    echo -e "${GREEN}上传目录: $APP_DIR/uploads${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    echo -e "${YELLOW}🚀 拉取最新官方镜像并重启容器...${RESET}"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Stb 图床已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Stb 图床已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f stb_app
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
