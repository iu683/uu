#!/bin/bash
# ========================================
# Lumina Theme 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="lumina-theme"
APP_DIR="/opt/$APP_NAME"

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}         Lumina Theme 管理菜单${RESET}"
        echo -e "${GREEN}========================================${RESET}"

        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        echo

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

    read -p "请输入哪吒面板地址 [默认:127.0.0.1]: " input_host
    NEZHA_HOST=${input_host:-127.0.0.1}

    read -p "请输入哪吒 RPC 端口 [默认:8008]: " input_nezha_port
    NEZHA_PORT=${input_nezha_port:-8008}

    read -p "请输入 Lumina 访问端口 [默认:3000]: " input_lumina_port
    LUMINA_PORT=${input_lumina_port:-3000}

    check_port "$LUMINA_PORT" || return

    read -p "请输入 Dashboard 用户名 [默认:admin]: " input_user
    LUMINA_DASHBOARD_USERNAME=${input_user:-admin}

    read -p "请输入 Dashboard 密码 [默认:admin123]: " input_pass
    LUMINA_DASHBOARD_PASSWORD=${input_pass:-admin123}

    cat > "$ENV_FILE" <<EOF
NEZHA_HOST=${NEZHA_HOST}
NEZHA_PORT=${NEZHA_PORT}

LUMINA_PORT=${LUMINA_PORT}

LUMINA_DASHBOARD_USERNAME=${LUMINA_DASHBOARD_USERNAME}
LUMINA_DASHBOARD_PASSWORD=${LUMINA_DASHBOARD_PASSWORD}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  lumina:
    image: ghcr.io/cytusc/lumina-theme:latest
    container_name: lumina-theme

    restart: unless-stopped

    ports:
      - "127.0.0.1:\${LUMINA_PORT}:80"

    extra_hosts:
      - "host.docker.internal:host-gateway"

    env_file:
      - .env
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Lumina Theme 安装完成${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${LUMINA_PORT}${RESET}"
    echo -e "${YELLOW}📡 哪吒地址: ${NEZHA_HOST}:${NEZHA_PORT}${RESET}"
    echo -e "${YELLOW}👤 Dashboard 用户名: ${LUMINA_DASHBOARD_USERNAME}${RESET}"
    echo -e "${YELLOW}🔐 Dashboard 密码: ${LUMINA_DASHBOARD_PASSWORD}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Lumina Theme 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart lumina-theme

    echo -e "${GREEN}✅ Lumina Theme 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f lumina-theme
}

check_status() {

    docker ps --filter "name=lumina-theme"

    read -p "按回车返回菜单..."
}

uninstall_app() {


    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Lumina Theme 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
