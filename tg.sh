#!/bin/bash
# ======================================
# ACGFaka 一键管理脚本 (端口映射模式 + MySQL + Redis)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="acgfaka"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== ACGFaka 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
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
    mkdir -p "$APP_DIR/acgfaka" "$APP_DIR/mysql"

    read -rp "请输入 Web 端口 [默认 8080]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-8080}

    read -rp "请输入 MySQL Root 密码: " MYSQL_ROOT_PASSWORD
    read -rp "请输入 MySQL 用户名 [默认 acgfakauser]: " MYSQL_USER
    MYSQL_USER=${MYSQL_USER:-acgfakauser}
    read -rp "请输入 MySQL 用户密码: " MYSQL_PASSWORD

    cat > "$COMPOSE_FILE" <<EOF


services:
  acgfaka:
    image: dapiaoliang666/acgfaka
    container_name: acgfaka
    ports:
      - "127.0.0.1:${WEB_PORT}:80"
    depends_on:
      - mysql
      - redis
    restart: always
    environment:
      PHP_OPCACHE_ENABLE: 1
      PHP_OPCACHE_MEMORY_CONSUMPTION: 128
      PHP_OPCACHE_MAX_ACCELERATED_FILES: 10000
      PHP_OPCACHE_REVALIDATE_FREQ: 2
      PHP_REDIS_HOST: redis
      PHP_REDIS_PORT: 6379
    volumes:
      - ./acgfaka:/var/www/html

  mysql:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: acgfakadb
      MYSQL_USER: $MYSQL_USER
      MYSQL_PASSWORD: $MYSQL_PASSWORD
    volumes:
      - ./mysql:/var/lib/mysql
    restart: always

  redis:
    image: redis:latest
    restart: always
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ ACGFaka 已启动${RESET}"
    echo -e "${GREEN}数据库地址: mysql${RESET}"
    echo -e "${GREEN}数据库名称: acgfakadb${RESET}"
    echo -e "${GREEN}数据库账号: $MYSQL_USER${RESET}"
    echo -e "${GREEN}数据库密码: $MYSQL_PASSWORD${RESET}"
    echo -e "${GREEN}访问地址: http://127.0.0.1:${WEB_PORT}${RESET}"
    echo -e "${GREEN}后台路径: http://127.0.0.1:${WEB_PORT}/admin${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ ACGFaka 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ ACGFaka 已卸载${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f acgfaka
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
