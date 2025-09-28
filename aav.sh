#!/bin/bash
set -e

GREEN="\033[32m"
RESET="\033[0m"
BASE_DIR="/opt/newapi"
DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$DATA_DIR/.env"

MYSQL_CONTAINER="newapi-mysql"
MYSQL_ROOT_PASSWORD="123456"
MYSQL_DB="newapi"
MYSQL_USER="newapi"
MYSQL_PASSWORD="newapi123"

DEFAULT_PORT=3000
API_PORT=$DEFAULT_PORT

mkdir -p "$DATA_DIR" "$LOG_DIR"

generate_env() {
    echo -e "${GREEN}生成 .env 文件...${RESET}"
    cat > "$ENV_FILE" <<EOF
SQL_DSN=$MYSQL_USER:$MYSQL_PASSWORD@tcp(mysql:3306)/$MYSQL_DB
REDIS_CONN_STRING=redis://redis
TZ=Asia/Shanghai
EOF
}

generate_compose() {
    echo -e "${GREEN}生成 docker-compose.yml 文件...${RESET}"
    cat > "$COMPOSE_FILE" <<EOF
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:$API_PORT:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    env_file:
      - ./data/.env
    depends_on:
      - redis
      - mysql

  redis:
    image: redis:latest
    container_name: redis
    restart: always

  mysql:
    image: mysql:8
    container_name: mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: $MYSQL_DB
    volumes:
      - mysql_data:/var/lib/mysql

volumes:
  mysql_data:
EOF
}

check_port() {
    if lsof -i:"$API_PORT" &>/dev/null; then
        echo -e "${GREEN}端口 $API_PORT 已被占用，请选择其他端口${RESET}"
        return 1
    fi
    return 0
}

init_database() {
    echo -e "${GREEN}等待 MySQL 启动...${RESET}"
    docker-compose -f "$COMPOSE_FILE" up -d mysql
    echo -e "${GREEN}初始化数据库...${RESET}"
    # 等待数据库就绪
    while ! docker exec -i mysql mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent; do
        sleep 2
    done
    docker exec -i mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS $MYSQL_DB;
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON $MYSQL_DB.* TO '$MYSQL_USER'@'%';
FLUSH PRIVILEGES;
EOF
    echo -e "${GREEN}数据库初始化完成${RESET}"
}

start_service() {
    read -p "请输入访问端口(默认 $DEFAULT_PORT): " PORT
    API_PORT=${PORT:-$DEFAULT_PORT}
    if ! check_port; then
        return
    fi

    mkdir -p "$BASE_DIR"
    generate_env
    generate_compose
    init_database
    docker-compose -f "$COMPOSE_FILE" up -d
    show_ip_port
}

stop_service() {
    docker-compose -f "$COMPOSE_FILE" down
}

restart_service() {
    stop_service
    start_service
}

update_service() {
    echo -e "${GREEN}正在拉取最新镜像...${RESET}"
    docker compose -f "$COMPOSE_FILE" pull
    docker compose -f "$COMPOSE_FILE" up -d
    echo -e "${GREEN}✅ 已更新并重启服务${RESET}"
}


uninstall_service() {
    stop_service
    rm -rf "$BASE_DIR"
}

show_logs_api() {
    docker logs -f new-api
}

show_logs_mysql() {
    docker logs -f mysql
}

show_ip_port() {
    IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}访问地址: http://127.0.0.1:$API_PORT${RESET}"
}


# 菜单循环
while true; do
    echo -e "${GREEN}====== New API 管理菜单 ======${RESET}"
    echo -e "${GREEN}1. 启动服务${RESET}"
    echo -e "${GREEN}2. 停止服务${RESET}"
    echo -e "${GREEN}3. 重启服务${RESET}"
    echo -e "${GREEN}4. 更新 New API${RESET}"
    echo -e "${GREEN}5. 卸载服务${RESET}"
    echo -e "${GREEN}6. 查看 New API 日志${RESET}"
    echo -e "${GREEN}7. 查看 MySQL 日志${RESET}"
    echo -e "${GREEN}8. 显示访问地址${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "请选择操作: " choice
    case $choice in
        1) start_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) update_service ;;
        5) uninstall_service; exit ;;
        6) show_logs_api ;;
        7) show_logs_mysql ;;
        8) show_ip_port ;;
        0) exit ;;
        *) echo "无效选项" ;;
    esac
done
