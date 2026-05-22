#!/bin/bash
# ========================================
# CPA Usage Keeper 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="cpa-usage-keeper"
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

        echo -e "${GREEN}=== CPA Usage Keeper 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/keeper"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 Web 端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    check_port "$PORT" || return

    echo
    read -p "请输入 CPA_BASE_URL [默认:http://cli-proxy-api:8317]: " input_base_url
    CPA_BASE_URL=${input_base_url:-http://cli-proxy-api:8317}

    read -p "请输入 CPA_MANAGEMENT_KEY: " CPA_MANAGEMENT_KEY

    read -p "请输入登录密码 LOGIN_PASSWORD: " LOGIN_PASSWORD

    cat > "$COMPOSE_FILE" <<EOF
services:
  cpa-usage-keeper:
    image: ghcr.io/willxup/cpa-usage-keeper:latest

    container_name: cpa-usage-keeper

    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:8080"

    environment:
      TZ: Asia/Shanghai
      CPA_BASE_URL: ${CPA_BASE_URL}
      CPA_MANAGEMENT_KEY: ${CPA_MANAGEMENT_KEY}
      REDIS_QUEUE_ADDR: cli-proxy-api:8317
      AUTH_ENABLED: true
      LOGIN_PASSWORD: ${LOGIN_PASSWORD}

    volumes:
      - ./keeper:/data

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ CPA Usage Keeper 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${YELLOW}🔗 CPA API:${RESET} ${CPA_BASE_URL}"
    echo -e "${YELLOW}📂 数据目录:${RESET} $APP_DIR/keeper"

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

    docker restart cpa-usage-keeper

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f cpa-usage-keeper
}

check_status() {

    docker ps | grep cpa-usage-keeper

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
