#!/bin/bash
# ========================================
# Telegram Sticker Alchemy 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="sticker-alchemy"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== Sticker Alchemy 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/tmp"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "请输入 Telegram Bot Token: " BOT_TOKEN
    read -p "请输入 OWNER_ID: " OWNER_ID
    
    read -p "TMP_DIR [默认:/tmp/sticker-alchemy]: " TMP_DIR
    TMP_DIR=${TMP_DIR:-/tmp/sticker-alchemy}

    cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${BOT_TOKEN}
OWNER_ID=${OWNER_ID}
PUBLIC_ACCESS=${PUBLIC_ACCESS}
TMP_DIR=${TMP_DIR}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  sticker-alchemy:
    image: ghcr.io/shuijiao1/telegram-sticker-alchemy:latest

    container_name: sticker-alchemy

    restart: unless-stopped

    env_file:
      - .env

    environment:
      TMP_DIR: \${TMP_DIR:-/tmp/sticker-alchemy}

    volumes:
      - ./data:/app/data
      - ./tmp:\${TMP_DIR:-/tmp/sticker-alchemy}

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Sticker Alchemy 已启动${RESET}"
    echo -e "${YELLOW}🤖 Bot Token: 已配置${RESET}"
    echo -e "${YELLOW}👤 Owner ID: ${OWNER_ID}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR/data${RESET}"

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

    docker restart sticker-alchemy

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f sticker-alchemy
}

check_status() {

    docker ps | grep sticker-alchemy

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
