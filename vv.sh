#!/bin/bash
# ========================================
# Emby-TG 管理
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="emby-tg"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/sd87671067/Emby-TG-.git"

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
        echo -e "${GREEN}=== Emby-TG 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装部署${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 状态检测${RESET}"
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

    echo -e "${GREEN}=== 开始配置 ===${RESET}"

    read -p "服务器IP或域名: " SERVER_IP
    read -p "Emby地址 (默认:http://127.0.0.1:8096): " EMBY_URL
    EMBY_URL=${EMBY_URL:-http://127.0.0.1:8096}

    read -p "Emby API Key: " EMBY_KEY

    read -p "管理员TG ID: " TG_ID
    read -p "管理员机器人Token: " ADMIN_BOT
    read -p "用户机器人Token: " CLIENT_BOT

    read -p "TG用户名(@xxx): " TG_USER

    MASTER_KEY=$(openssl rand -hex 16)

    cat > .env <<EOF
APP_NAME=Emby TG 管理中心
APP_ENV=production
APP_PORT=18080
APP_BASE_URL=http://${SERVER_IP}:18080
APP_TIMEZONE=Asia/Shanghai
APP_MASTER_KEY=${MASTER_KEY}
APP_WEB_ADMIN_USERNAME=admin
APP_WEB_ADMIN_PASSWORD=Admin@123456

EMBY_BASE_URL=${EMBY_URL}
EMBY_API_KEY=${EMBY_KEY}
EMBY_SERVER_PUBLIC_URL=http://${SERVER_IP}:8096
EMBY_TEMPLATE_USER=testone

ADMIN_BOT_TOKEN=${ADMIN_BOT}
ADMIN_CHAT_IDS=${TG_ID}
CLIENT_BOT_TOKEN=${CLIENT_BOT}

ADMIN_CONTACT_TG_USERNAME=${TG_USER}
ADMIN_CONTACT_TG_USER_ID=${TG_ID}
EOF


    docker compose up -d --build


    echo
    echo -e "${GREEN}✅ 安装完成${RESET}"

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
    docker restart emby-tg-app 2>/dev/null || docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    echo -e "${YELLOW}=== 容器状态 ===${RESET}"
    docker ps | grep emby

    echo
    echo -e "${YELLOW}=== 端口检测 ===${RESET}"
    ss -tlnp | grep 18080 || echo "端口未监听"

    echo
    echo -e "${YELLOW}=== Emby 连通性 ===${RESET}"
    curl -s --max-time 5 "$EMBY_URL" >/dev/null && echo "Emby 可访问" || echo "Emby 访问失败"

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
