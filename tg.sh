#!/bin/bash
# ===========================
# TinyAuth 管理脚本 (菜单版)
# - 只手动输入 bcrypt 用户
# - 端口绑定 127.0.0.1
# ===========================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="tinyauth"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== TinyAuth 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR"

    read -rp "请输入访问端口 [默认 2082]: " port
    port=${port:-2082}

    read -rp "请输入 APP_URL (例如 https://dookku.vvmn.me): " appurl
    appurl=${appurl:-http://127.0.0.1:$port}

    read -rp "请输入 SECRET (推荐 32 位随机字符串，回车自动生成): " secret
    secret=${secret:-$(openssl rand -hex 16)}

    # 强制手动输入用户配置
    echo -e "${YELLOW}请输入用户配置 (格式 user:bcrypt_hash)${RESET}"
    read -rp "用户配置: " USERS_STRING

    # 将 USERS 用单引号包裹，避免 $ 被解析
    cat > "$COMPOSE_FILE" <<EOF
services:
  tinyauth:
    container_name: tinyauth
    image: ghcr.io/steveiliop56/tinyauth:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:$port:3000"
    environment:
      - SECRET=${secret}
      - APP_URL=${appurl}
      - USERS='${USERS_STRING}'
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ TinyAuth 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: ${appurl}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    echo -e "${GREEN}🔑 SECRET: $secret${RESET}"

    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ TinyAuth 已更新并重启${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ TinyAuth 已卸载${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f tinyauth
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
