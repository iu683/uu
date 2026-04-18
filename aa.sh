#!/bin/bash
# ========================================
# Lumina (WARP Client) 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="lumina"
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
    if ss -tlnp 2>/dev/null | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
    return 0
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Lumina 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -rp "$(echo -e ${GREEN}请选择:${RESET}) " choice

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
    cd "$APP_DIR" || exit

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖？(y/n)${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -rp "请输入 WebUI 端口 [默认:8000]: " input_web
    WEB_PORT=${input_web:-8000}
    check_port "$WEB_PORT" || return

    read -rp "请输入 SOCKS5 端口 [默认:1080]: " input_socks
    SOCKS_PORT=${input_socks:-1080}
    check_port "$SOCKS_PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  lumina:
    image: crisocean/lumina:latest
    container_name: lumina-client
    restart: unless-stopped
    environment:
      WARP_BACKEND: usque
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "127.0.0.1:${WEB_PORT}:8000"
      - "127.0.0.1:${SOCKS_PORT}:1080"
    volumes:
      - lumina_data:/var/lib/cloudflare-warp
      - lumina_usque:/var/lib/warp
      - lumina_config:/app/data

volumes:
  lumina_data:
  lumina_usque:
  lumina_config:
EOF

    docker compose pull || {
        echo -e "${RED}❌ 镜像拉取失败${RESET}"
        return
    }

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Lumina 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI: http://127.0.0.1:${WEB_PORT}${RESET}"
    echo -e "${YELLOW}🧦 SOCKS5: 127.0.0.1:${SOCKS_PORT}${RESET}"

    read -rp "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -rp "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -rp "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -rp "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已彻底卸载${RESET}"
    read -rp "按回车返回菜单..."
}

menu
