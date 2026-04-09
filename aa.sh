#!/bin/bash
# ========================================
# Conflux 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="conflux"
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
        echo -e "${GREEN}=== Conflux 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "请输入 Web 面板端口 [默认:80]: " input_web
    WEB_PORT=${input_web:-80}
    check_port "$WEB_PORT" || return

    echo
    read -p "请输入代理端口 [默认:7890]: " input_proxy
    PROXY_PORT=${input_proxy:-7890}
    check_port "$PROXY_PORT" || return

    echo
    read -p "请输入管理员密码 (留空自动生成): " input_pass
    ADMIN_PASS=${input_pass:-$(openssl rand -hex 8)}

    JWT_SECRET=$(openssl rand -hex 32)

cat > "$COMPOSE_FILE" <<EOF
services:
  conflux:
    image: veildawn/conflux:latest
    container_name: conflux
    restart: unless-stopped
    ports:
      - "127.0.0.1:${WEB_PORT}:80"
      - "127.0.0.1:${PROXY_PORT}:7890"
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - ADMIN_PASSWORD=${ADMIN_PASS}
    volumes:
      - conflux-config:/app/mihomo/config
      - conflux-data:/app/backend/data

volumes:
  conflux-config:
  conflux-data:
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Conflux 已启动${RESET}"
    echo -e "${YELLOW}🌐 面板地址: http://127.0.0.1:${WEB_PORT}${RESET}"
    echo -e "${GREEN}🔑 管理密码: ${ADMIN_PASS}${RESET}"
    echo -e "${GREEN}🔐 JWT_SECRET: ${JWT_SECRET}${RESET}"
    echo -e "${GREEN}🌐 代理端口: ${PROXY_PORT}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Conflux 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart conflux
    echo -e "${GREEN}✅ Conflux 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f conflux
}

check_status() {
    docker ps | grep conflux
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Conflux 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
