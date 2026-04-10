#!/bin/bash
# ========================================
# MTLogin 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mtlogin"
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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MTLogin 管理菜单 ===${RESET}"
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

    echo
    read -p "请输入用户名 USERNAME: " USERNAME

    echo
    read -p "请输入密码 PASSWORD: " PASSWORD

    echo
    read -p "请输入 TOTPSECRET(动态验证码): " input_totp
    TOTPSECRET=${input_totp:-$(openssl rand -hex 10)}

    echo
    read -p "请输入 CRONTAB 定时任务 [默认:0 3 * * 1]: " input_cron
    CRONTAB=${input_cron:-"0 3 * * 1"}

    echo
    read -p "请输入 Telegram Bot Token: " TGBOT_TOKEN

    echo
    read -p "请输入 Telegram Chat ID: " TGBOT_CHAT_ID

    echo
    read -p "请输入数据库路径 [默认:$APP_DIR/auth.db]: " input_db
    DB_PATH=${input_db:-$APP_DIR/auth.db}

    mkdir -p "$(dirname "$DB_PATH")"
    touch "$DB_PATH"

cat > "$COMPOSE_FILE" <<EOF
services:
    mtlogin:
        container_name: mtlogin
        image: ghcr.io/scjtqs2/mtlogin:edge
        restart: unless-stopped
        volumes:
            - ${APP_DIR}:/data
        environment:
            - USERNAME=${USERNAME}
            - PASSWORD=${PASSWORD}
            - TOTPSECRET=${TOTPSECRET}
            - CRONTAB=${CRONTAB}
            - TGBOT_TOKEN=${TGBOT_TOKEN}
            - TGBOT_CHAT_ID=${TGBOT_CHAT_ID}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ MTLogin 已启动${RESET}"
    echo -e "${GREEN}👤 用户名: ${USERNAME}${RESET}"
    echo -e "${GREEN}🔑 密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}🔐 TOTPSECRET: ${TOTPSECRET}${RESET}"
    echo -e "${GREEN}📂 数据库: ${DB_PATH}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MTLogin 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart mtlogin
    echo -e "${GREEN}✅ MTLogin 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f mtlogin
}

check_status() {
    docker ps | grep mtlogin
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MTLogin 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
