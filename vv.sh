#!/bin/bash
# ========================================
# Emby Pulse 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="emby-pulse"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_DIR="$APP_DIR/config"

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

# 获取服务器IP
SERVER_IP=$(hostname -I | awk '{print $1}')

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Emby Pulse 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$APP_DIR/static/img"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入时区 [默认:Asia/Shanghai]: " input_tz
    TZ=${input_tz:-Asia/Shanghai}

    read -p "请输入 Emby 主机地址 [例如:http://192.168.31.2:8096]: " input_host
    EMBY_HOST=${input_host:-http://192.168.31.2:8096}

    read -p "请输入 Emby API Key [例如:xxxxxxxxxxxxxxxxx]: " input_key
    EMBY_API_KEY=${input_key:-xxxxxxxxxxxxxxxxx}

    # 数据库宿主机路径
    read -p "请输入数据库宿主机路径 [例如:/volume1/docker/emby/data]: " input_db_host
    DB_HOST_PATH=${input_db_host:-/volume1/docker/emby/data}

    # 数据库容器内部路径
    read -p "请输入数据库容器路径 [例如:/emby-data/playback_reporting.db]: " input_db_container
    DB_CONTAINER_PATH=${input_db_container:-/emby-data/playback_reporting.db}


    cat > "$COMPOSE_FILE" <<EOF
services:
  emby-pulse:
    image: zeyu8023/emby-stats:latest
    container_name: emby-pulse
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${DB_HOST_PATH}:/emby-data
      - ./config:/app/config
    environment:
      - TZ=${TZ}
      - DB_PATH=${DB_CONTAINER_PATH}
      - EMBY_HOST=${EMBY_HOST}
      - EMBY_API_KEY=${EMBY_API_KEY}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Emby Pulse 已启动${RESET}"
    echo -e "${GREEN}✅ webui http://${SERVER_IP}:10307${RESET}"
    echo -e "${GREEN}✅ 默认账号密码：直接使用您的Emby管理员账号和密码登录${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Emby Pulse 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart emby-pulse
    echo -e "${GREEN}✅ Emby Pulse 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f emby-pulse
}

check_status() {
    docker ps | grep emby-pulse
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Emby Pulse 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
