#!/bin/bash
# ========================================
# nginxpulse 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="nginxpulse"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== nginxpulse 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/docker_local/logs"
    mkdir -p "$APP_DIR/docker_local/nginxpulse_data"
    mkdir -p "$APP_DIR/docker_local/pgdata"
    mkdir -p "$APP_DIR/docker_local/configs"

    chmod -R 777 "$APP_DIR/docker_local"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口(默认:8088): " p1
    PORT1=${p1:-8088}
    check_port "$PORT1" || return

    read -p "请输入API端口(默认:8089): " p2
    PORT2=${p2:-8089}
    check_port "$PORT2" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  nginxpulse:
    image: magiccoders/nginxpulse:latest
    container_name: nginxpulse
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT1}:8088"
      - "${PORT2}:8089"
    volumes:
      - ./docker_local/logs:/share/logs
      - ./docker_local/nginxpulse_data:/app/var/nginxpulse_data
      - ./docker_local/pgdata:/app/var/pgdata
      - ./docker_local/configs:/app/configs
      - /etc/localtime:/etc/localtime:ro
    stop_grace_period: 90s
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ nginxpulse 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web: http://127.0.0.1:${PORT1}${RESET}"
    echo -e "${YELLOW}📊 API: http://127.0.0.1:${PORT2}${RESET}"

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
    docker restart nginxpulse
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f nginxpulse
}

check_status() {
    docker ps | grep nginxpulse
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
