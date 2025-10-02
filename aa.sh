#!/bin/bash
# ========================================
# One-API 一键管理脚本 (Docker Compose) - 无MySQL版
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="one-api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== One-API 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    mkdir -p "$APP_DIR"/{data,logs}

    # 输入参数
    read -p "请输入 Web 端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    read -p "请输入 SESSION_SECRET (随机字符串, 默认随机生成): " input_secret
    SESSION_SECRET=${input_secret:-$(openssl rand -hex 16)}

    # 写 config.env
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
SESSION_SECRET=$SESSION_SECRET
EOF

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  one-api:
    image: justsong/one-api:latest
    container_name: one-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:\${PORT}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - REDIS_CONN_STRING=redis://redis
      - SESSION_SECRET=\${SESSION_SECRET}
      - TZ=Asia/Shanghai
    depends_on:
      - redis

  redis:
    image: redis:latest
    container_name: redis
    restart: always
EOF

    cd "$APP_DIR"
    docker compose --env-file "$CONFIG_FILE" up -d

    echo -e "${GREEN}✅ One-API 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 账号/密码: root/123456${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📂 日志目录: $APP_DIR/logs${RESET}"
    echo -e "${GREEN}🔑 SESSION_SECRET: $SESSION_SECRET${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" pull
    docker compose --env-file "$CONFIG_FILE" up -d
    echo -e "${GREEN}✅ One-API 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" restart
    echo -e "${GREEN}✅ One-API 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f one-api
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ One-API 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
