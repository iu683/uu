#!/bin/bash
# ========================================
# SongLoft 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="songloft"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

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

        echo -e "${GREEN}=== SongLoft 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
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

    echo
    read -p "访问端口 [默认:58091]: " input_port
    PORT=${input_port:-58091}
    check_port "$PORT" || return

    read -p "管理员用户名 [默认:admin]: " input_user
    ADMIN_USER=${input_user:-admin}

    DEFAULT_PASS=$(generate_password)
    read -p "管理员密码 [默认随机生成]: " input_pass
    ADMIN_PASS=${input_pass:-$DEFAULT_PASS}

    read -p "音乐目录路径 [必填，如 /mnt/music]: " MUSIC_DIR

    if [ -z "$MUSIC_DIR" ]; then
        echo -e "${RED}音乐目录不能为空！${RESET}"
        sleep 2
        return
    fi

    mkdir -p "$MUSIC_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  songloft:
    image: songloft/songloft:latest

    container_name: songloft

    restart: always

    ports:
      - "127.0.0.1:${PORT}:${PORT}"

    volumes:
      - ${MUSIC_DIR}:/app/music
      - ./data:/app/data

    environment:
      ADMIN_USERNAME: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASS}
      LISTEN_PORT: ${PORT}

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ SongLoft 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}👤 用户名: ${ADMIN_USER}${RESET}"
    echo -e "${YELLOW}🔐 密码: ${ADMIN_PASS}${RESET}"
    echo -e "${YELLOW}🎵 音乐目录: ${MUSIC_DIR}${RESET}"
    echo -e "${YELLOW}📂 数据目录: ${APP_DIR}/data${RESET}"

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

    docker restart songloft

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f songloft
}

check_status() {

    docker ps | grep songloft

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
