#!/bin/bash
# ========================================
# IPTV-VTG4 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="iptv-vtg4"
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
        echo -e "${GREEN}=====IPTV-VTG4 管理菜单=====${RESET}"
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

    read -p "请输入访问端口 [默认:10801]: " input_port
    PORT=${input_port:-10801}

    check_port "$PORT" || return

    read -p "请输入管理员用户名 [默认:admin]: " input_user
    ADMIN_USERNAME=${input_user:-admin}

    read -p "请输入管理员密码 [默认:admin123]: " input_pass
    ADMIN_PASSWORD=${input_pass:-admin123}

    read -p "请输入播放 Token [默认:abc123]: " input_token
    PLAY_TOKEN=${input_token:-abc123}

    cat > "$ENV_FILE" <<EOF
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
PLAY_TOKEN=${PLAY_TOKEN}

PORT=${PORT}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  vtg4_rust:
    image: instituteiptv/iptv-vtg4:latest
    container_name: vtg4_rust

    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:10801"

    environment:
      - ADMIN_USERNAME=\${ADMIN_USERNAME}
      - ADMIN_PASSWORD=\${ADMIN_PASSWORD}
      - PLAY_TOKEN=\${PLAY_TOKEN}
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ IPTV-VTG4 安装完成${RESET}"

    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"

    echo -e "${YELLOW}👤 管理员用户名: ${ADMIN_USERNAME}${RESET}"

    echo -e "${YELLOW}🔐 管理员密码: ${ADMIN_PASSWORD}${RESET}"

    echo -e "${YELLOW}🎫 PLAY_TOKEN: ${PLAY_TOKEN}${RESET}"


    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ IPTV-VTG4 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart vtg4_rust

    echo -e "${GREEN}✅ IPTV-VTG4 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f vtg4_rust
}

check_status() {

    docker ps --filter "name=vtg4_rust"

    read -p "按回车返回菜单..."
}

uninstall_app() {


    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ IPTV-VTG4 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
