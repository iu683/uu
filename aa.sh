#!/bin/bash
# ========================================
# TG-SignPulse 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tg-signpulse"
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

generate_secret() {

    openssl rand -hex 32
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== TG-SignPulse 管理菜单 ===${RESET}"
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

    read -p "请输入服务端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    check_port "$PORT" || return

    echo
    read -p "请输入管理员密码: " ADMIN_PASSWORD

    SECRET_KEY=$(generate_secret)

    cat > "$COMPOSE_FILE" <<EOF
services:
  app:
    image: ghcr.io/akasls/tg-signpulse:latest
    container_name: tg-signpulse

    restart: unless-stopped

    ports:
      - "${PORT}:8080"

    volumes:
      - ./data:/data

    environment:
      PORT: 8080
      TZ: Asia/Shanghai
      APP_DATA_DIR: /data
      APP_SECRET_KEY: ${SECRET_KEY}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}

    init: true

    read_only: true

    tmpfs:
      - /tmp
      - /app/__pycache__

    security_opt:
      - no-new-privileges:true

    cap_drop:
      - ALL

    stop_grace_period: 30s

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ TG-SignPulse 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${YELLOW}🔑 管理密码:${RESET} ${ADMIN_PASSWORD}"
    echo -e "${YELLOW}📂 数据目录:${RESET} $APP_DIR/data"

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

    docker restart tg-signpulse

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f tg-signpulse
}

check_status() {

    docker ps | grep tg-signpulse

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
