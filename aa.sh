#!/bin/bash
# ========================================
# NewsNow 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="newsnow"
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
        echo -e "${GREEN}=== NewsNow 管理菜单 ===${RESET}"
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

    read -p "请输入访问端口 [默认:4444]: " input_port
    PORT=${input_port:-4444}
    check_port "$PORT" || return

    read -p "请输入 Github Client ID : " G_CLIENT_ID
    read -p "请输入 Github Client Secret: " G_CLIENT_SECRET

    JWT_SECRET=$(openssl rand -hex 16)

    cat > "$COMPOSE_FILE" <<EOF
services:
  newsnow:
    image: ghcr.io/ourongxing/newsnow:latest
    container_name: newsnow
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:4444"
    volumes:
      - newsnow_data:/usr/app/.data
    environment:
      HOST: 0.0.0.0
      PORT: 4444
      NODE_ENV: production
      G_CLIENT_ID: ${G_CLIENT_ID}
      G_CLIENT_SECRET: ${G_CLIENT_SECRET}
      JWT_SECRET: ${JWT_SECRET}
      INIT_TABLE: true
      ENABLE_CACHE: true
      PRODUCTHUNT_API_TOKEN:

volumes:
  newsnow_data:
    name: newsnow_data
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ NewsNow 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据卷: newsnow_data${RESET}"
    echo -e "${YELLOW} 首次启动后建议把 INIT_TABLE 改为 false${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ NewsNow 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart newsnow
    echo -e "${GREEN}✅ NewsNow 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f newsnow
}

check_status() {
    docker ps | grep newsnow
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    docker volume rm newsnow_data 2>/dev/null
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ NewsNow 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
