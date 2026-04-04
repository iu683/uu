#!/bin/bash
# ========================================
# WordPress 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="wordpress"
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
        echo -e "${GREEN}=== WordPress 管理菜单 ===${RESET}"
        echo -e "1) 安装启动"
        echo -e "2) 更新"
        echo -e "3) 重启"
        echo -e "4) 查看日志"
        echo -e "5) 查看状态"
        echo -e "6) 卸载"
        echo -e "0) 退出"
        read -p "请选择: " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
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

    read -p "请输入数据目录 [默认:$APP_DIR/data]: " input_data
    DATA_DIR=${input_data:-$APP_DIR/data}
    mkdir -p "$DATA_DIR"

cat > "$COMPOSE_FILE" <<EOF
services:
  wordpress:
    image: wordpress:latest
    container_name: wordpress-server
    restart: always
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - ${DATA_DIR}:/var/www/html
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ WordPress 已启动${RESET}"
    echo -e "${YELLOW}访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}数据目录: ${DATA_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart wordpress-server
    echo -e "${GREEN}已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f wordpress-server
}

check_status() {
    docker ps | grep wordpress-server
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
