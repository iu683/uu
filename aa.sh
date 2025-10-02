#!/bin/bash
# ========================================
# vue-color-avatar 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="vue-color-avatar"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 用户运行脚本${RESET}"
        exit 1
    fi
}

install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}安装 Docker...${RESET}"
        apt update
        apt install -y docker.io
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${GREEN}安装 Docker Compose 插件...${RESET}"
        apt install -y docker-compose-plugin
    fi
    if ! systemctl is-active --quiet docker; then
        echo -e "${GREEN}启动 Docker 服务...${RESET}"
        systemctl enable docker
        systemctl start docker
    fi
}

install_app() {
    install_docker
    mkdir -p "$APP_DIR"

    read -p "请输入映射端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}

    if [ -d "$APP_DIR/.git" ]; then
        echo -e "${GREEN}检测到已有代码，更新中...${RESET}"
        cd "$APP_DIR"
        git pull
    else
        echo -e "${GREEN}克隆代码...${RESET}"
        git clone https://github.com/Codennnn/vue-color-avatar.git "$APP_DIR"
        cd "$APP_DIR"
    fi

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  vue-color-avatar:
    build: .
    image: vue-color-avatar:latest
    container_name: vue-color-avatar
    ports:
      - "127.0.0.1:\${PORT}:80"
    restart: always
EOF

    cd "$APP_DIR"
    PORT=$PORT docker compose up -d --build

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}✅ vue-color-avatar 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂数据目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
    menu
}

update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    docker compose pull 
    docker compose up -d
    echo -e "${GREEN}✅ 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    docker compose restart
    echo -e "${GREEN}✅ 服务已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    echo -e "${GREEN}日志输出（Ctrl+C 退出）...${RESET}"
    docker compose logs --tail 100 -f
    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录${RESET}"
        read -p "按回车返回菜单..."
        menu
    fi
    cd "$APP_DIR"
    docker compose down -v --rmi all
    cd ~
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载并删除数据${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu() {
    clear
    echo -e "${GREEN}=== vue-color-avatar 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 重启服务${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) view_logs ;;
        5) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ; menu ;;
    esac
}

check_root
menu
