#!/bin/bash
# ========================================
# Fakabot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="fakabot"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/yanguo888/fakabot.git"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Fakabot 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装部署${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否重新安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    git clone "$REPO_URL" "$APP_DIR" || {
        echo -e "${RED}克隆失败${RESET}"
        return
    }

    cd "$APP_DIR" || exit

    echo -e "${GREEN}=== 基础配置 ===${RESET}"

    read -p "请输入 Telegram Bot Token: " BOT_TOKEN
    read -p "请输入你的 Telegram ID: " ADMIN_ID
    read -p "请输入域名(可留空): " DOMAIN

    # 生成 config.json
    cat > config.json <<EOF
{
  "BOT_TOKEN": "${BOT_TOKEN}",
  "ADMIN_ID": ${ADMIN_ID},
  "DOMAIN": "${DOMAIN}",
  "ORDER_TIMEOUT_SECONDS": 3600,
  "PAYMENTS": {},
  "START": {
    "cover_url": "",
    "title": "欢迎使用",
    "intro": "请在 config.json 中自定义内容"
  },
  "SHOW_QR": true,
  "PRODUCTS": []
}
EOF

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Fakabot 已启动${RESET}"
    echo -e "${YELLOW}👉 请先给机器人发送 /start${RESET}"
    echo -e "${YELLOW}👉 配置文件: /opt/$APP_NAME/config.json${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    git pull
    docker compose up -d --build
    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart fakabot 2>/dev/null || docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    echo -e "${YELLOW}=== 容器状态 ===${RESET}"
    docker ps | grep fakabot

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
