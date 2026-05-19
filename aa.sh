#!/bin/bash
# ========================================
# Mimo2API 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mimo2api"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"

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

        echo -e "${GREEN}=== Mimo2API 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入服务端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    check_port "$PORT" || return

    if [ ! -f "$CONFIG_FILE" ]; then

cat > "$CONFIG_FILE" <<EOF
{
  "api_keys": "sk-mimo",
  "mimo_accounts": [
    {
      "service_token": "YOUR_SERVICE_TOKEN",
      "user_id": "YOUR_USER_ID",
      "xiaomichatbot_ph": "YOUR_XIAOMICHATBOT_PH"
    }
  ]
}
EOF

    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  mimo2api:
    image: ghcr.io/fly143/mimo2api:latest
    container_name: mimo2api

    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:8080"

    volumes:
      - ./config.json:/app/config.json
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Mimo2API 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}⚙️ 配置文件: $CONFIG_FILE${RESET}"

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

    docker restart mimo2api

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f mimo2api
}

check_status() {

    docker ps | grep mimo2api

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
