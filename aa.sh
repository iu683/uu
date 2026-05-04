#!/bin/bash
# ========================================
# GPT-Image-Linux 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="gpt-image"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="gpt-image"

REPO="https://github.com/Z1rconium/gpt-image-linux.git"

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "0.0.0.0"
}

menu() {
    clear
    echo -e "${GREEN}=== GPT-Image 管理菜单 ===${RESET}"
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
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

install_app() {

    echo -e "${GREEN}检查 Docker...${RESET}"

    if ! command -v docker &>/dev/null; then
        apt update
        apt install -y curl
        curl -fsSL https://get.docker.com | bash
    fi

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then
        echo -e "${GREEN}克隆项目...${RESET}"
        git clone "$REPO" "$APP_DIR"
    fi

    cd "$APP_DIR" || exit

    echo
    echo -e "${GREEN}配置 .env${RESET}"

    read -p "API URL (默认 https://api.openai.com): " API_URL
    read -p "API KEY (必填): " API_KEY
    read -p "访问密码 ACCESS_KEY (可留空): " ACCESS_KEY

    [ -z "$API_URL" ] && API_URL="https://api.openai.com"

    cat > .env <<EOF
DEFAULT_API_URL=$API_URL
DEFAULT_API_KEY=$API_KEY
DEFAULT_API_PATH=/v1/images/generations
DEFAULT_RESPONSES_MODEL=gpt-4.1

ACCESS_KEY=$ACCESS_KEY
IP_ALLOWLIST=

TRUST_PROXY_HEADERS=false
MAX_FILE_SIZE_MB=50

IMAGES_DIR=./images
DATA_DIR=./data

PYTHON_BASE_IMAGE=python:3.11-slim
EOF

    echo -e "${GREEN}启动服务...${RESET}"
    docker compose up -d --build

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ GPT-Image 已启动${RESET}"
    echo -e "${YELLOW}访问: http://${SERVER_IP}:3000${RESET}"

    [ -n "$ACCESS_KEY" ] && echo -e "${YELLOW}访问密码: $ACCESS_KEY${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${GREEN}更新代码...${RESET}"
    git pull

    echo -e "${GREEN}重新构建...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
    menu
}

restart_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

view_logs() {

    docker compose logs -f

    read -p "按回车返回菜单..."
    menu
}

check_status() {

    echo -e "${GREEN}容器状态：${RESET}"
    docker ps | grep gpt-image

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

menu
