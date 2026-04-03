#!/bin/bash
# ========================================
# MongoDB 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mongo"
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
        echo -e "${GREEN}=== MongoDB 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "MongoDB 用户名 [默认:admin]: " input_user
    DB_USER=${input_user:-admin}

    read -p "MongoDB 密码 [默认:YourStrongPwd2024!]: " input_pass
    DB_PASS=${input_pass:-YourStrongPwd2024!}

    read -p "业务数据库名 [默认:myappdb]: " input_db
    DB_NAME=${input_db:-myappdb}

    read -p "MongoDB 端口 [默认:27017]: " input_port
    PORT=${input_port:-27017}
    check_port "$PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  mongo:
    image: mongo:6.0
    container_name: mongo-dev
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${DB_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${DB_PASS}
      MONGO_INITDB_DATABASE: ${DB_NAME}
    volumes:
      - ./data:/data/db
    ports:
      - "127.0.0.1:${PORT}:27017"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ MongoDB 已启动${RESET}"
    echo -e "${YELLOW}📡 地址: mongodb://${DB_USER}:${DB_PASS}@127.0.0.1:${PORT}/${DB_NAME}?authSource=admin${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/data${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MongoDB 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart mongo-dev
    echo -e "${GREEN}✅ MongoDB 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f mongo-dev
}

check_status() {
    docker ps | grep mongo-dev
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MongoDB 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
