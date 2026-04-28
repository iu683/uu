#!/bin/bash
# ========================================
# one-api 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="one-api"
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
        echo -e "${GREEN}=== one-api 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR/data/mysql"
    mkdir -p "$APP_DIR/data/oneapi"
    mkdir -p "$APP_DIR/logs"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    read -p "MySQL root密码 [默认:StrongRoot123!]: " input_root
    MYSQL_ROOT_PASS=${input_root:-StrongRoot123!}

    read -p "MySQL 用户密码 [默认:StrongUser123!]: " input_user
    MYSQL_USER_PASS=${input_user:-StrongUser123!}

    read -p "Redis密码 [默认:StrongRedis123!]: " input_rd
    REDIS_PASS=${input_rd:-StrongRedis123!}

    SESSION_SECRET=$(openssl rand -hex 16)

    cat > "$COMPOSE_FILE" <<EOF
services:
  one-api:
    image: justsong/one-api:latest
    container_name: one-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - ./data/oneapi:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=oneapi:${MYSQL_USER_PASS}@tcp(db:3306)/one-api
      - REDIS_CONN_STRING=redis://:${REDIS_PASS}@redis:6379
      - SESSION_SECRET=${SESSION_SECRET}
      - TZ=Asia/Shanghai
    depends_on:
      - redis
      - db

  redis:
    image: redis:latest
    container_name: redis
    restart: always
    command: ["redis-server", "--requirepass", "${REDIS_PASS}"]

  db:
    image: mysql:8.2.0
    container_name: mysql
    restart: always
    volumes:
      - ./data/mysql:/var/lib/mysql
    environment:
      TZ: Asia/Shanghai
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_USER: oneapi
      MYSQL_PASSWORD: ${MYSQL_USER_PASS}
      MYSQL_DATABASE: one-api
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ one-api 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR${RESET}"

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
    docker restart one-api
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f one-api
}

check_status() {
    docker ps | grep one-api
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
