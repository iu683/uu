#!/bin/bash

# ========================================
# Sun Panel 一键管理脚本 Alpine兼容版
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"

APP_NAME="sun-panel"
COMPOSE_DIR="/opt/sun-panel"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DEFAULT_PORT=3002

# 自动识别 compose
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    echo -e "${RED}未安装 Docker Compose${RESET}"
    echo -e "${YELLOW}正在自动安装...${RESET}"

    apk add docker-cli-compose >/dev/null 2>&1

    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    else
        echo -e "${RED}安装失败${RESET}"
        exit 1
    fi
fi

function menu() {
    clear
    echo -e "${GREEN}=== Sun Panel 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启${RESET}"
    echo -e "${GREEN}4) 卸载(含数据)${RESET}"
    echo -e "${GREEN}5) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "请选择: " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) uninstall_app ;;
        5) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {

    read -p "请输入 Web 端口 [默认:${DEFAULT_PORT}]: " input_port
    PORT=${input_port:-$DEFAULT_PORT}

    mkdir -p "$COMPOSE_DIR/conf"

    cat > "$COMPOSE_FILE" <<EOF
services:
  sun-panel:
    image: hslr/sun-panel:latest
    container_name: sun-panel
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3002"
    volumes:
      - ${COMPOSE_DIR}/conf:/app/conf
      - /var/run/docker.sock:/var/run/docker.sock
EOF

    cd "$COMPOSE_DIR" || exit

    $DOCKER_COMPOSE pull
    $DOCKER_COMPOSE up -d

    sleep 3

    if docker ps | grep -q sun-panel; then
        echo -e "${GREEN}✅ ${APP_NAME} 已启动${RESET}"
        echo -e "${YELLOW}🌐 本机访问地址: http://127.0.0.1:${PORT}${RESET}"
        echo -e "${GREEN}账号: admin@sun.cc${RESET}"
        echo -e "${GREEN}密码: 12345678${RESET}"
        echo -e "${GREEN}📂 配置目录: $COMPOSE_DIR/conf${RESET}"
    else
        echo -e "${RED}❌ 启动失败${RESET}"
        docker logs sun-panel
    fi

    read -p "按回车返回菜单..."
    menu
}

function update_app() {

    cd "$COMPOSE_DIR" || {
        echo -e "${RED}未安装${RESET}"
        sleep 1
        menu
    }

    $DOCKER_COMPOSE pull
    $DOCKER_COMPOSE up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function restart_app() {

    cd "$COMPOSE_DIR" || {
        echo -e "${RED}未安装${RESET}"
        sleep 1
        menu
    }

    $DOCKER_COMPOSE restart

    echo -e "${GREEN}✅ 重启完成${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {

    cd "$COMPOSE_DIR" || {
        echo -e "${RED}未安装${RESET}"
        sleep 1
        menu
    }

    $DOCKER_COMPOSE down -v

    rm -rf "$COMPOSE_DIR"

    echo -e "${GREEN}✅ 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f sun-panel
}

menu
