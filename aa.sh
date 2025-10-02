#!/bin/bash
# ========================================
# new-api 一键管理脚本 (Docker Compose + 可选 MySQL + Healthcheck)
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

function install_app() {
    mkdir -p "$APP_DIR"/{data,logs}

    read -rp "请输入 Web 端口 [默认:3000]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-3000}

    read -rp "是否使用 MySQL？(y/n, 默认 n): " use_mysql
    use_mysql=${use_mysql:-n}

    SQL_ENV=""
    MYSQL_SECTION=""
    MYSQL_HEALTH=""
    if [[ "$use_mysql" == "y" || "$use_mysql" == "Y" ]]; then
        read -rp "MySQL 连接地址 [默认:127.0.0.1]: " MYSQL_HOST
        MYSQL_HOST=${MYSQL_HOST:-l27.0.0.1}

        read -rp "MySQL port [默认:3306]: " MYSQL_PORT
        MYSQL_PORT=${MYSQL_PORT:-3306}

        read -rp "MySQL root 密码: " MYSQL_ROOT_PASSWORD
        read -rp "数据库名 [默认:new_api]: " MYSQL_DATABASE
        MYSQL_DATABASE=${MYSQL_DATABASE:-new_api}

        read -rp "普通用户 [默认:newuser]: " MYSQL_USER
        MYSQL_USER=${MYSQL_USER:-newuser}

        read -rp "用户密码 [默认:password]: " MYSQL_PASSWORD
        MYSQL_PASSWORD=${MYSQL_PASSWORD:-password}

        SQL_ENV=$(cat <<EOF
SQL_DSN=${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${MYSQL_DATABASE}?charset=utf8mb4&parseTime=True&loc=Local
EOF
)

        # 健康检查 MySQL
        MYSQL_HEALTH=$(cat <<EOF
  mysql:
    image: mysql:8.2
    container_name: new-api-mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./mysql:/var/lib/mysql
    command: --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u${MYSQL_USER}", "-p${MYSQL_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF
)
    fi

    read -rp "请输入 SESSION_SECRET (默认随机生成): " input_secret
    SESSION_SECRET=${input_secret:-$(openssl rand -hex 16)}

    # 写 config.env
    cat > "$CONFIG_FILE" <<EOF
WEB_PORT=$WEB_PORT
SESSION_SECRET=$SESSION_SECRET
TZ=Asia/Shanghai
$SQL_ENV
EOF

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    ports:
      - "127.0.0.1:\${WEB_PORT}:3000"
    environment:
      - SESSION_SECRET=\${SESSION_SECRET}
      - TZ=\${TZ}
EOF

    if [[ -n "$SQL_ENV" ]]; then
        echo "      - SQL_DSN=\${SQL_DSN}" >> "$COMPOSE_FILE"
        echo "    depends_on:" >> "$COMPOSE_FILE"
        echo "      - mysql" >> "$COMPOSE_FILE"
    fi

    # Healthcheck Web 接口
    cat >> "$COMPOSE_FILE" <<EOF
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -q '\"success\": true'"]
      interval: 30s
      timeout: 10s
      retries: 5
    volumes:
      - ./data:/data
      - ./logs:/logs
EOF

    # 加 MySQL 服务
    if [[ -n "$MYSQL_HEALTH" ]]; then
        echo "$MYSQL_HEALTH" >> "$COMPOSE_FILE"
    fi

    cd "$APP_DIR"
    docker compose --env-file "$CONFIG_FILE" up -d

    echo -e "${GREEN}✅ new-api 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$WEB_PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"
    echo -e "${GREEN}📂 日志目录: $APP_DIR/logs${RESET}"
    echo -e "${GREEN}🔑 SESSION_SECRET: $SESSION_SECRET${RESET}"
    if [[ -n "$SQL_ENV" ]]; then
        echo -e "${GREEN}🗄️ MySQL 数据库: $MYSQL_DATABASE${RESET}"
        echo -e "${GREEN}👤 用户: $MYSQL_USER / $MYSQL_PASSWORD${RESET}"
        echo -e "${GREEN}数据库初始化请等待，容器健康检查启动完毕${RESET}"
    else
        echo -e "${YELLOW}📦 使用本地 SQLite 数据库 (./data)${RESET}"
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
