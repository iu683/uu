#!/bin/bash
# ========================================
# tg-disk 一键管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tg-disk"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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
        echo -e "${GREEN}=== tg-disk 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "请输入 BOT_TOKEN: " BOT_TOKEN
    read -p "请输入 CHAT_ID: " CHAT_ID
    read -p "请输入访问密码 [默认:yohann]: " input_pwd
    ACCESS_PWD=${input_pwd:-yohann}

    read -p "是否使用代理(留空跳过): " PROXY
    read -p "请输入 BASE_URL(文件访问基础 URL可留空): " BASE_URL

    # 写入 .env
    cat > "$ENV_FILE" <<EOF
PORT=${PORT}
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}
ACCESS_PWD=${ACCESS_PWD}
PROXY=${PROXY}
BASE_URL=${BASE_URL}

DOWNLOAD_THREADS=8
CHUNK_SIZE_MB=10
CHUNK_CONCURRENT=4
FILES_CONCURRENT=2
EOF

    # 写入 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  tg-disk:
    image: ghcr.io/yohann0617/tg-disk:master
    container_name: tg-disk
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8080"
    volumes:
      - ${ENV_FILE}:/app/.env
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ tg-disk 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 配置文件: $ENV_FILE${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ tg-disk 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart tg-disk
    echo -e "${GREEN}✅ tg-disk 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f tg-disk
}

check_status() {
    docker ps | grep tg-disk
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ tg-disk 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
