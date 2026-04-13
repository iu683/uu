#!/bin/bash
# ========================================
# dongguaTV 一键管理脚本（最终稳定版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="dongguatv"
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
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== dongguaTV 管理菜单 ===${RESET}"
        echo "1) 安装启动"
        echo "2) 更新"
        echo "3) 重启"
        echo "4) 查看日志"
        echo "5) 查看状态"
        echo "6) 卸载(含数据)"
        echo "0) 退出"
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

    read -p "端口 [默认:3600]: " input_port
    PORT=${input_port:-3600}
    check_port "$PORT" || return

    read -p "TMDB API KEY: " TMDB_API_KEY
    [ -z "$TMDB_API_KEY" ] && echo "必须填写！" && return

    read -p "管理员密码 [默认:admin]: " input_pass
    ADMIN_PASSWORD=${input_pass:-admin}

    cat > "$COMPOSE_FILE" <<EOF
services:
  dongguatv:
    image: aexus/dongguatv:latest
    container_name: dongguatv
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - TMDB_API_KEY=${TMDB_API_KEY}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ 启动成功${RESET}"
    echo -e "${YELLOW}访问：http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}密码：${ADMIN_PASSWORD}${RESET}"

    read -p "回车继续..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo "✅ 更新完成"
    read -p "回车继续..."
}

restart_app() {
    docker restart dongguatv
    echo "✅ 已重启"
    read -p "回车继续..."
}

view_logs() {
    docker logs -f dongguatv
}

check_status() {
    docker ps | grep dongguatv
    read -p "回车继续..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo "✅ 已卸载"
    read -p "回车继续..."
}

menu
