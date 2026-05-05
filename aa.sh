#!/bin/bash
# ========================================
# qBittorrent-TGBot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="qbittorrent-tgbot"
APP_DIR="/opt/$APP_NAME"

REPO="https://github.com/Polarisiu/qBittorrent-TGBot.git"

menu() {
    clear
    echo -e "${GREEN}=== qBittorrent-TGBot 管理菜单 ===${RESET}"
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
    cd "$APP_DIR" || exit

    if [ ! -d ".git" ]; then
        echo -e "${GREEN}克隆项目...${RESET}"
        git clone "$REPO" .
    fi

    echo -e "${GREEN}配置 .env${RESET}"

    read -p "请输入 BOT_TOKEN: " BOT_TOKEN
    read -p "请输入TGID: " ALLOWED_USER_IDS

    read -p "qBittorrent 地址 [默认:http://127.0.0.1:8080]: " QB_URL
    read -p "qB 用户名 [默认:admin]: " QB_USER
    read -p "qB 密码 [默认:adminadmin]: " QB_PASS

    read -p "下载目录 [默认:/data/downloads]: " SAVE_PATH

    [ -z "$QB_URL" ] && QB_URL="http://127.0.0.1:8080"
    [ -z "$QB_USER" ] && QB_USER="admin"
    [ -z "$QB_PASS" ] && QB_PASS="adminadmin"
    [ -z "$SAVE_PATH" ] && SAVE_PATH="/data/downloads"

    cat > .env <<EOF
BOT_TOKEN=$BOT_TOKEN
ALLOWED_USER_IDS=$ALLOWED_USER_IDS

QB_URL=$QB_URL
QB_USER=$QB_USER
QB_PASS=$QB_PASS

DEFAULT_SAVE_PATH=$SAVE_PATH
PRESET_DIRS=影视:$SAVE_PATH/movies,音乐:$SAVE_PATH/music,软件:$SAVE_PATH/apps
POLL_INTERVAL=20
EOF

    echo -e "${GREEN}启动服务...${RESET}"
    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ qBittorrent-TGBot 已启动${RESET}"
    echo -e "${YELLOW}Bot 已连接 Telegram，请发送 /start 测试${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    echo -e "${GREEN}拉取更新...${RESET}"
    git pull

    echo -e "${GREEN}重新构建...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
    menu
}

restart_app() {

    cd "$APP_DIR" || return
    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

view_logs() {

    cd "$APP_DIR" || return
    docker compose logs -f

    read -p "按回车返回菜单..."
    menu
}

check_status() {

    echo -e "${GREEN}容器状态：${RESET}"
    docker ps | grep qbittorrent-tgbot

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
