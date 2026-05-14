#!/bin/bash
# ========================================
# AIClient2API 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="aiclient2api"
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

        echo -e "${GREEN}=== AIClient2API 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 编辑配置目录${RESET}"
        echo -e "${GREEN}7) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) edit_configs ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR/configs"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入主 API 端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    echo
    echo -e "${YELLOW}8085-8087 / 1455 / 19876-19880 也会占用${RESET}"
    echo

    read -p "请输入启动参数 ARGS [可留空]: " ARGS

    cat > "$COMPOSE_FILE" <<EOF
services:
  aiclient-api:
    image: justlikemaki/aiclient-2-api:latest
    container_name: aiclient2api
    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:3000"
      - "127.0.0.1:8085-8087:8085-8087"
      - "127.0.0.1:1455:1455"
      - "127.0.0.1:19876-19880:19876-19880"

    volumes:
      - ./configs:/app/configs

    environment:
      ARGS: ${ARGS}

    healthcheck:
      test: ["CMD", "node", "healthcheck.js"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ AIClient2API 已启动${RESET}"
    echo -e "${YELLOW}🌐 API 地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${GREEN}📂 配置目录:${RESET} $APP_DIR/configs"

    if [ -n "$ARGS" ]; then
        echo -e "${GREEN}⚙️ ARGS:${RESET} ${ARGS}"
    fi

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

    docker restart aiclient2api

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f aiclient2api
}

check_status() {

    docker ps | grep aiclient2api

    read -p "按回车返回菜单..."
}

edit_configs() {

    nano "$APP_DIR/configs/config.json"

    echo -e "${GREEN}✅ 配置编辑完成${RESET}"

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
