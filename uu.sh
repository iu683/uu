#!/bin/bash
# ========================================
# new-api 一键管理脚本 (Docker Compose) - 可选MySQL版 (含检测)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="new-api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== new-api 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
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

function check_mysql() {
    echo -e "${YELLOW}🔍 正在检测 MySQL 连接...${RESET}"
    if ! command -v mysqladmin >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ 未检测到 mysqladmin，正在尝试安装...${RESET}"
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y mysql-client
        elif command -v yum >/dev/null 2>&1; then
            yum install -y mysql
        else
            echo -e "${RED}❌ 无法安装 mysqladmin，请手动安装 mysql-client${RESET}"
            return 1
        fi
    fi

    mysqladmin -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" ping --silent >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ MySQL 连接成功${RESET}"
        return 0
    else
        echo -e "${RED}❌ 无法连接到 MySQL，请检查地址/端口/用户名/密码${RESET}"
        return 1
    fi
}

function install_app() {
    mkdir -p "$APP_DIR"/{data,logs}

    read -p "请输入 Web 端口 [默认:3000]: " PORT
    PORT=${PORT:-3000}

    read -p "请输入 SESSION_SECRET (随机字符串, 默认随机生成): " SESSION_SECRET
    SESSION_SECRET=${SESSION_SECRET:-$(openssl rand -hex 16)}

    echo -e "${YELLOW}是否使用外部 MySQL？(回车默认使用 SQLite)${RESET}"
    read -p "输入 y 表示使用外部 MySQL: " use_mysql

    SQL_DSN=""
    if [[ "$use_mysql" == "y" || "$use_mysql" == "Y" ]]; then
        read -p "请输入 MySQL 地址 [默认:127.0.0.1]: " MYSQL_HOST
        MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}

        read -p "请输入 MySQL 端口 [默认:3306]: " MYSQL_PORT
        MYSQL_PORT=${MYSQL_PORT:-3306}

        read -p "请输入 MySQL 用户名 [默认:root]: " MYSQL_USER
        MYSQL_USER=${MYSQL_USER:-root}

        read -p "请输入 MySQL 密码 [默认:123456]: " MYSQL_PASSWORD
        MYSQL_PASSWORD=${MYSQL_PASSWORD:-123456}

        read -p "请输入 MySQL 数据库名 [默认:new_api]: " MYSQL_DATABASE
        MYSQL_DATABASE=${MYSQL_DATABASE:-new_api}

        SQL_DSN="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${MYSQL_DATABASE}?charset=utf8mb4&parseTime=True&loc=Local"

        # 检测 MySQL 是否可连
        check_mysql || { read -p "按回车返回菜单..."; menu; }
    fi

    # 写 config.env
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
SESSION_SECRET=$SESSION_SECRET
SQL_DSN=$SQL_DSN
EOF

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:\${PORT}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SESSION_SECRET=\${SESSION_SECRET}
      - REDIS_CONN_STRING=redis://redis
      - TZ=Asia/Shanghai
EOF

    if [[ -n "$SQL_DSN" ]]; then
        echo "      - SQL_DSN=\${SQL_DSN}" >> "$COMPOSE_FILE"
    fi

    cat >> "$COMPOSE_FILE" <<EOF

  redis:
    image: redis:latest
    container_name: redis
    restart: always
EOF

    cd "$APP_DIR"
    docker compose --env-file "$CONFIG_FILE" up -d

    echo -e "${GREEN}✅ new-api 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}🔑 账号/密码: root/123456${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📂 日志目录: $APP_DIR/logs${RESET}"
    echo -e "${GREEN}🔑 SESSION_SECRET: $SESSION_SECRET${RESET}"
    echo -e "${GREEN}提示: 数据库初始化需要时间，请等待一分钟再访问${RESET}"
    if [[ -n "$SQL_DSN" ]]; then
        echo -e "${GREEN}🗄️ 使用外部 MySQL 数据库: $MYSQL_DATABASE (主机: $MYSQL_HOST:$MYSQL_PORT 用户: $MYSQL_USER)${RESET}"
    else
        echo -e "${YELLOW}📦 当前使用 SQLite 本地数据库 (文件存储在 ./data 目录)${RESET}"
    fi

    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" pull
    docker compose --env-file "$CONFIG_FILE" up -d
    echo -e "${GREEN}✅ new-api 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" restart
    echo -e "${GREEN}✅ new-api 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f new-api
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose --env-file "$CONFIG_FILE" down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ new-api 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
