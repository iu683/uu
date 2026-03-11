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

    # 创建目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$APP_DIR/static/img"

    # 已安装检测
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 1️⃣ 时区
    read -p "请输入时区 [默认:Asia/Shanghai]: " input_tz
    TZ=${input_tz:-Asia/Shanghai}

    # 2️⃣ Emby 主机地址
    read -p "请输入 Emby 主机地址 [例如:http://192.168.31.2:8096]: " input_host
    EMBY_HOST=${input_host:-http://192.168.31.2:8096}

    # 3️⃣ Emby API Key
    read -p "请输入 Emby API Key [例如:xxxxxxxxxxxxxxxxx]: " input_key
    EMBY_API_KEY=${input_key:-xxxxxxxxxxxxxxxxx}

    # 4️⃣ 可选数据库路径
    read -p "请输入数据库宿主机路径（可选，API模式可不填）: " input_db_host
    DB_HOST_PATH=${input_db_host}
    read -p "请输入数据库容器路径（可选，API模式可不填）: " input_db_container
    DB_CONTAINER_PATH=${input_db_container}

    # 5️⃣ 宿主机端口
    read -p "请输入 Emby Pulse WebUI 宿主机端口 [默认:10307]: " input_port
    HOST_PORT=${input_port:-10307}
    CONTAINER_PORT=10307

    # 构建 volumes 和 environment 列表
    VOLUMES_LIST=("      - ./config:/app/config")  # config 必挂
    ENV_LIST=("      - TZ=${TZ}" "      - EMBY_HOST=${EMBY_HOST}" "      - EMBY_API_KEY=${EMBY_API_KEY}")

    # 如果用户填写了数据库路径，则挂载并设置 DB_PATH
    if [ -n "$DB_HOST_PATH" ] && [ -n "$DB_CONTAINER_PATH" ]; then
        VOLUMES_LIST+=("      - ${DB_HOST_PATH}:${DB_CONTAINER_PATH}")
        ENV_LIST+=("      - DB_PATH=${DB_CONTAINER_PATH}/playback_reporting.db")
    fi

    # 写入 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  emby-pulse:
    image: zeyu8023/emby-stats:latest
    container_name: emby-pulse
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}"
    volumes:
$(printf "%s\n" "${VOLUMES_LIST[@]}")
    environment:
$(printf "%s\n" "${ENV_LIST[@]}")
EOF

    # 启动容器
    cd "$APP_DIR" || exit
    docker compose up -d

    # 获取本机 IP
    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${GREEN}✅ Emby Pulse 已启动${RESET}"
    echo -e "${GREEN}✅ WebUI: http://127.0.0.1:${HOST_PORT}${RESET}"
    echo -e "${GREEN}✅ 默认账号密码: 使用您的 Emby 管理员账号登录${RESET}"
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
