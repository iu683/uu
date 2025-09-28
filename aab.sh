#!/bin/bash
# ========================================
# Sehuatang-Crawler 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="magnetboard"
APP_DIR="$HOME/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function get_ip() {
    echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== magnetboard 管理菜单 ===${RESET}"
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
    read -p "请输入 Web 端口 [默认:8000]: " input_port
    WEB_PORT=${input_port:-8000}

    read -p "请输入管理员密码 [默认:admin123]: " input_pass
    ADMIN_PASSWORD=${input_pass:-admin123}

    mkdir -p "$APP_DIR"

    cat > "$COMPOSE_FILE" <<EOF

services:
  sehuatang-crawler:
    image: wyh3210277395/magnetboard:latest
    container_name: magnetboard
    ports:
      - "127.0.0.1:${WEB_PORT}:8000"
    environment:
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_NAME=sehuatang_db
      - DATABASE_USER=postgres
      - DATABASE_PASSWORD=postgres123
      - PYTHONPATH=/app/backend
      - ENVIRONMENT=production
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
    volumes:
      - sehuatang_data:/app/data
      - sehuatang_logs:/app/logs
    depends_on:
      - postgres
    restart: unless-stopped

  postgres:
    image: postgres:15-alpine
    container_name: sehuatang-postgres
    ports:
      - "127.0.0.1:5432:5432"
    environment:
      - POSTGRES_DB=sehuatang_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres123
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  sehuatang_data:
  sehuatang_logs:
  postgres_data:

networks:
  default:
    name: sehuatang-network
EOF

    echo "WEB_PORT=$WEB_PORT" > "$CONFIG_FILE"
    echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ magnetboard 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$WEB_PORT${RESET}"
    echo -e "${GREEN}📂 数据卷: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ magnetboard 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ magnetboard 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f magnetboard
    read -p "按回车返回菜单..."
    menu
}

menu
