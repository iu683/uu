#!/bin/bash
# ========================================
# MoviePilot 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="moviepilot"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== MoviePilot 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
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

function install_app() {
    read -p "请输入 Nginx Web端口 [默认:3000]: " input_web
    PORT_WEB=${input_web:-3000}
    read -p "请输入 API端口 [默认:3001]: " input_api
    PORT_API=${input_api:-3001}

    read -p "请输入管理员账号 [默认:admin]: " ADMIN
    ADMIN=${ADMIN:-admin}
    read -p "请输入管理员密码 [默认:admin123]: " ADMIN_PWD
    ADMIN_PWD=${ADMIN_PWD:-admin123}

    # 创建统一目录
    mkdir -p "$APP_DIR"/{media,config,core,torrents,bt_backup,redis,postgresql}

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  redis:
    image: redis:latest
    container_name: redis
    restart: always
    volumes:
      - $APP_DIR/redis/data:/data
    command: redis-server --save 600 1 --requirepass redis_password
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "redis_password", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

  postgresql:
    image: postgres:latest
    container_name: postgresql
    restart: always
    environment:
      POSTGRES_DB: moviepilot
      POSTGRES_USER: moviepilot
      POSTGRES_PASSWORD: pg_password
    volumes:
      - $APP_DIR/postgresql/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U moviepilot -d moviepilot"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

  pgloader:
    image: dimitri/pgloader:latest
    container_name: pgloader
    restart: "no"
    volumes:
      - $APP_DIR/config:/mp_config
    command: >
      pgloader
      sqlite:///mp_config/user.db
      postgresql://moviepilot:pg_password@postgresql:5432/moviepilot
    depends_on:
      postgresql:
        condition: service_healthy

  moviepilot:
    image: jxxghp/moviepilot-v2:latest
    container_name: moviepilot-v2
    hostname: moviepilot-v2
    stdin_open: true
    tty: true
    restart: always
    ports:
      - "127.0.0.1:$PORT_WEB:3000"
      - "127.0.0.1:$PORT_API:3001"
    volumes:
      - $APP_DIR/media:/media
      - $APP_DIR/config:/config
      - $APP_DIR/core:/moviepilot/.cache/ms-playwright
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $APP_DIR/torrents:/torrents
      - $APP_DIR/bt_backup:/BT_backup
    environment:
      - NGINX_PORT=$PORT_WEB
      - PORT=$PORT_API
      - PUID=0
      - PGID=0
      - UMASK=000
      - TZ=Asia/Shanghai
      - SUPERUSER=$ADMIN
      - SUPERUSER_PASSWORD=$ADMIN_PWD
      - DB_TYPE=postgresql
      - DB_POSTGRESQL_HOST=postgresql
      - DB_POSTGRESQL_PORT=5432
      - DB_POSTGRESQL_DATABASE=moviepilot
      - DB_POSTGRESQL_USERNAME=moviepilot
      - DB_POSTGRESQL_PASSWORD=pg_password
      - CACHE_BACKEND_TYPE=redis
      - CACHE_BACKEND_URL=redis://:redis_password@redis:6379
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
      pgloader:
        condition: service_completed_successfully

networks:
  default:
    name: moviepilot-network
EOF

    # 保存配置
    echo "PORT_WEB=$PORT_WEB" > "$CONFIG_FILE"
    echo "PORT_API=$PORT_API" >> "$CONFIG_FILE"
    echo "SUPERUSER=$ADMIN" >> "$CONFIG_FILE"
    echo "SUPERUSER_PASSWORD=$ADMIN_PWD" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ MoviePilot 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI: http://127.0.0.1:$PORT_WEB${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    read -p "按回车返回菜单..."
    menu
}


function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MoviePilot 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ MoviePilot 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f moviepilot-v2
    read -p "按回车返回菜单..."
    menu
}

menu
