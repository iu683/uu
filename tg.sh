#!/bin/bash
# ========================================
# Koodo Reader 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="koodo-reader"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
SECRET_FILE="$APP_DIR/my_secret.txt"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Koodo Reader 管理菜单 ===${RESET}"
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
    read -p "请输入 web端口 [默认:80]: " input_web
    PORT_WEB=${input_web:-80}

    read -p "请输入 数据源端口 [默认:8080]: " input_http
    PORT_HTTP=${input_http:-8080}

    read -p "请输入管理用户名 [默认:admin]: " input_user
    USERNAME=${input_user:-admin}

    read -p "请输入管理密码 [默认:admin123]: " input_pwd
    PASSWORD=${input_pwd:-admin123}

    mkdir -p "$APP_DIR/uploads"

    # 写入 secret 文件
    echo "$PASSWORD" > "$SECRET_FILE"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF


services:
  koodo-reader:
    image: ghcr.io/koodo-reader/koodo-reader:master
    container_name: koodo-reader
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT_WEB:80"
      - "127.0.0.1:$PORT_HTTP:8080"
    environment:
      - SERVER_USERNAME=$USERNAME
      - SERVER_PASSWORD_FILE=my_secret
      - ENABLE_HTTP_SERVER=false
    volumes:
      - $APP_DIR/uploads:/app/uploads
    secrets:
      - my_secret

secrets:
  my_secret:
    file: $SECRET_FILE
EOF

    echo "PORT_HTTP=$PORT_HTTP" > "$CONFIG_FILE"
    echo "PORT_WEB=$PORT_WEB" >> "$CONFIG_FILE"
    echo "USERNAME=$USERNAME" >> "$CONFIG_FILE"
    echo "PASSWORD=$PASSWORD" >> "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Koodo Reader 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT_WEB${RESET}"
    echo -e "${GREEN}📂 上传目录: $APP_DIR/uploads${RESET}"
    echo -e "${GREEN}🔑 管理员账号: $USERNAME  密码: $PASSWORD${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Koodo Reader 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Koodo Reader 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f koodo-reader
    read -p "按回车返回菜单..."
    menu
}

menu
