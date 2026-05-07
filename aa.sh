#!/bin/bash
# ========================================
# Checkmate 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="checkmate"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Checkmate 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "请选择: " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
        esac
    done
}

install_app() {

    check_docker
    mkdir -p "$APP_DIR/data/mongo"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:52345]: " input_port
    PORT=${input_port:-52345}
    check_port "$PORT" || return

    JWT=$(openssl rand -hex 32)

    read -p "请输入访问地址 [默认:http://127.0.0.1:${PORT}]: " input_host
    BASE_URL=${input_host:-http://127.0.0.1:${PORT}}

    cat > "$COMPOSE_FILE" <<EOF
services:
  server:
    image: ghcr.io/bluewave-labs/checkmate-backend-mono:latest
    container_name: checkmate
    restart: always
    ports:
      - "127.0.0.1:${PORT}:52345"
    environment:
      UPTIME_APP_API_BASE_URL: ${BASE_URL}/api/v1
      UPTIME_APP_CLIENT_HOST: ${BASE_URL}
      CLIENT_HOST: ${BASE_URL}
      DB_CONNECTION_STRING: mongodb://mongodb:27017/uptime_db
      JWT_SECRET: ${JWT}
    depends_on:
      - mongodb

  mongodb:
    image: ghcr.io/bluewave-labs/checkmate-mongo:latest
    container_name: checkmate-mongo
    restart: always
    command: ["mongod", "--quiet", "--bind_ip_all"]
    volumes:
      - ./data/mongo:/data/db
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Checkmate 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${YELLOW}🔑 JWT_SECRET: ${JWT}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart checkmate checkmate-mongo
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f checkmate
}

check_status() {
    docker ps | grep checkmate
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
