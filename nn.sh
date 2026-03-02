#!/bin/bash
# ========================================
# MTG 一键管理脚本（Host 模式）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mtg"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="mtg"

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

random_port() {
    while :; do
        PORT=$(shuf -i 10000-65535 -n1)
        ss -tln | grep -q ":$PORT " || break
    done
    echo "$PORT"
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MTG 管理菜单 ===${RESET}"
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

    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(random_port)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    read -p "请输入伪装域名 [默认 bing.com]: " input_domain
    DOMAIN=${input_domain:-bing.com}

    SECRET=$(docker run --rm nineseconds/mtg:master generate-secret --hex $DOMAIN)

    cat > "$APP_DIR/config.toml" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:${PORT}"
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  mtg:
    image: nineseconds/mtg:master
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    volumes:
      - $APP_DIR/config.toml:/config.toml
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${GREEN}✅ MTG 已启动${RESET}"
    echo -e "${YELLOW}🌐 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔐 Secret: ${SECRET}${RESET}"
    echo
    echo -e "${GREEN}📎 Telegram 代理链接:${RESET}"
    echo -e "${YELLOW}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}${RESET}"
    echo
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MTG 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ MTG 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f ${CONTAINER_NAME}
}

check_status() {
    docker ps | grep ${CONTAINER_NAME}
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MTG 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
