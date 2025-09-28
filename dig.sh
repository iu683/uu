#!/bin/bash
set -e

# ================== 颜色定义 ==================
GREEN="\033[32m"
RESET="\033[0m"

# ================== 固定目录 ==================
WORKDIR="/opt/oneapi"
COMPOSE_FILE="$WORKDIR/docker-compose.yml"
BACKUP_DIR="$WORKDIR/backup"
DATE=$(date +%Y%m%d_%H%M%S)

DB_CONTAINER="mysql"
ONEAPI_CONTAINER="oneapi"
DB_USER="oneapi"
DB_PASSWORD="123456"
DB_NAME="oneapi"

mkdir -p "$WORKDIR" "$BACKUP_DIR"
cd "$WORKDIR"

# ================== 检查依赖 ==================
check_env() {
    if ! command -v docker &>/dev/null; then
        echo -e "${GREEN}错误: 未安装 Docker${RESET}"
        exit 1
    fi
    if ! command -v docker-compose &>/dev/null; then
        echo -e "${GREEN}错误: 未安装 docker-compose${RESET}"
        exit 1
    fi
}

# ================== 获取本机 IP ==================
get_ip() {
    hostname -I | awk '{print $1}'
}

# ================== 生成 Compose 文件 ==================
generate_compose() {
    echo -e "${GREEN}请输入 OneAPI 映射端口 (默认 3001): ${RESET}"
    read ONEAPI_PORT
    ONEAPI_PORT=${ONEAPI_PORT:-3001}

    echo -e "${GREEN}请输入 MySQL 映射端口 (默认 3306): ${RESET}"
    read MYSQL_PORT
    MYSQL_PORT=${MYSQL_PORT:-3306}

    echo -e "${GREEN}请输入 SESSION_SECRET (直接回车则自动生成随机值): ${RESET}"
    read SESSION_SECRET
    if [ -z "$SESSION_SECRET" ]; then
        SESSION_SECRET=$(openssl rand -hex 32)
        echo -e "${GREEN}已生成随机 SESSION_SECRET: $SESSION_SECRET${RESET}"
    fi

    mkdir -p "$WORKDIR/data" "$WORKDIR/mysql"

    cat > $COMPOSE_FILE <<EOF
services:
  db:
    image: mysql:8.4
    restart: always
    container_name: $DB_CONTAINER
    networks:
      - oneapi
    volumes:
      - $WORKDIR/mysql:/var/lib/mysql
    ports:
      - "${MYSQL_PORT}:3306"
    environment:
      TZ: Asia/Shanghai
      MYSQL_ROOT_PASSWORD: "OneAPI@justsongStrong"
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: "${DB_PASSWORD}"
      MYSQL_DATABASE: ${DB_NAME}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u${DB_USER}", "-p${DB_PASSWORD}"]
      interval: 5s
      retries: 20
      start_period: 20s

  one-api:
    image: "justsong/one-api:latest"
    container_name: $ONEAPI_CONTAINER
    restart: always
    networks:
      - oneapi
    ports:
      - "127.0.0.1:${ONEAPI_PORT}:3000"
    volumes:
      - $WORKDIR/data:/data
    environment:
      - SQL_DSN=${DB_USER}:${DB_PASSWORD}@tcp(db:3306)/${DB_NAME}
      - SESSION_SECRET=${SESSION_SECRET}
      - TZ=Asia/Shanghai
    depends_on:
      db:
        condition: service_healthy

networks:
  oneapi:
EOF

    echo "$ONEAPI_PORT" > "$WORKDIR/.oneapi_port"
    echo "$MYSQL_PORT" > "$WORKDIR/.mysql_port"
    echo "$SESSION_SECRET" > "$WORKDIR/.session_secret"

    echo -e "${GREEN}docker-compose.yml 已生成 (已包含健康检查)${RESET}"
    echo -e "${GREEN}OneAPI 端口: $ONEAPI_PORT, MySQL 端口: $MYSQL_PORT${RESET}"
}

# ================== 功能函数 ==================
deploy_services() {
    generate_compose
    docker-compose -f $COMPOSE_FILE up -d
    sleep 3
    echo -e "${GREEN}服务已部署并启动${RESET}"
    IP=$(get_ip)
    PORT=$(cat "$WORKDIR/.oneapi_port")
    echo -e "${GREEN}访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}OneAPI 初始账号用户名为 root，密码为 123456${RESET}"
}

start_services() {
    docker-compose -f $COMPOSE_FILE up -d
    echo -e "${GREEN}服务已启动${RESET}"
}

stop_services() {
    docker-compose -f $COMPOSE_FILE down
    echo -e "${GREEN}服务已停止${RESET}"
}

restart_services() {
    docker-compose -f $COMPOSE_FILE down
    docker-compose -f $COMPOSE_FILE up -d
    echo -e "${GREEN}服务已重启${RESET}"
}

update_services() {
    echo -e "${GREEN}正在拉取最新镜像...${RESET}"
    docker-compose -f $COMPOSE_FILE pull
    docker-compose -f $COMPOSE_FILE up -d
    echo -e "${GREEN}镜像已更新并重启服务${RESET}"
}

logs_oneapi() {
    docker logs -f $ONEAPI_CONTAINER
}

logs_db() {
    docker logs -f $DB_CONTAINER
}

enter_oneapi() {
    docker exec -it $ONEAPI_CONTAINER /bin/sh
}

enter_db() {
    docker exec -it $DB_CONTAINER /bin/bash
}

backup_db() {
    mkdir -p $BACKUP_DIR
    FILE="$BACKUP_DIR/${DB_NAME}_${DATE}.sql"
    docker exec $DB_CONTAINER mysqldump -u$DB_USER -p$DB_PASSWORD $DB_NAME > $FILE
    echo -e "${GREEN}数据库已备份: $FILE${RESET}"
}

restore_db() {
    echo -e "${GREEN}请输入要恢复的备份文件路径:${RESET}"
    read FILE
    if [ ! -f "$FILE" ]; then
        echo -e "${GREEN}文件不存在${RESET}"
        return
    fi
    docker exec -i $DB_CONTAINER mysql -u$DB_USER -p$DB_PASSWORD $DB_NAME < "$FILE"
    echo -e "${GREEN}数据库已恢复${RESET}"
}

remove_all() {
    echo -e "${GREEN}警告: 将删除所有容器和数据！是否继续？(y/n)${RESET}"
    read confirm
    if [ "$confirm" == "y" ]; then
        docker-compose -f $COMPOSE_FILE down -v
        rm -rf "$WORKDIR/data" "$WORKDIR/mysql" "$WORKDIR/backup" "$WORKDIR/.oneapi_port" "$WORKDIR/.mysql_port" "$WORKDIR/.session_secret"
        echo -e "${GREEN}容器和数据已删除${RESET}"
    else
        echo "已取消操作"
    fi
}

show_config() {
    if [ -f "$WORKDIR/.oneapi_port" ]; then
        ONEAPI_PORT=$(cat "$WORKDIR/.oneapi_port")
        MYSQL_PORT=$(cat "$WORKDIR/.mysql_port")
        SESSION_SECRET=$(cat "$WORKDIR/.session_secret")
        IP=$(get_ip)
        echo -e "${GREEN}当前配置:${RESET}"
        echo -e "${GREEN}  OneAPI 地址: http://${IP}:${ONEAPI_PORT}${RESET}"
        echo -e "${GREEN}  MySQL 端口: ${MYSQL_PORT}${RESET}"
        echo -e "${GREEN}  SESSION_SECRET: ${SESSION_SECRET}${RESET}"
    else
        echo -e "${GREEN}未检测到已部署配置${RESET}"
    fi
}

# ================== 菜单 ==================
menu() {
    clear
    echo -e "${GREEN}====== OneAPI 一键部署管理菜单 ======${RESET}"
    echo -e "${GREEN}1.  部署并启动服务${RESET}"
    echo -e "${GREEN}2.  启动服务${RESET}"
    echo -e "${GREEN}3.  停止服务${RESET}"
    echo -e "${GREEN}4.  重启服务${RESET}"
    echo -e "${GREEN}5.  更新${RESET}"
    echo -e "${GREEN}6.  查看 OneAPI日志${RESET}"
    echo -e "${GREEN}7.  查看 MySQL日志${RESET}"
    echo -e "${GREEN}8.  进入 OneAPI容器${RESET}"
    echo -e "${GREEN}9.  进入 MySQL容器${RESET}"
    echo -e "${GREEN}10. 备份数据库${RESET}"
    echo -e "${GREEN}11. 恢复数据库${RESET}"
    echo -e "${GREEN}12. 删除所有容器和数据${RESET}"
    echo -e "${GREEN}13. 查看当前配置${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo "================================="
}

# ================== 主循环 ==================
check_env
while true; do
    menu
    read -p "请选择操作: " choice
    case $choice in
        1) deploy_services ;;
        2) start_services ;;
        3) stop_services ;;
        4) restart_services ;;
        5) update_services ;;
        6) logs_oneapi ;;
        7) logs_db ;;
        8) enter_oneapi ;;
        9) enter_db ;;
        10) backup_db ;;
        11) restore_db ;;
        12) remove_all ;;
        13) show_config ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}" ;;
    esac
    read -p "按回车键返回菜单..."
done
