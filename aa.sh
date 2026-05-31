#!/bin/bash
# ========================================
# OmePic 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="omepic"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/OuOumm/OmePic.git"

generate_secret() {
    openssl rand -hex 32
}

generate_aes_key() {
    openssl rand -hex 16
}

check_docker() {

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== OmePic 管理菜单 ===${RESET}"
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

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    echo

    read -p "请输入端口 [默认8080]: " input_port
    APP_PORT=${input_port:-8080}

    read -p "请输入管理员密码 ADMIN_PASSWORD: " ADMIN_PASSWORD
    read -p "请输入公网域名(如 https://img.xxx.com): " PUBLIC_BASE_URL

    JWT_SECRET=$(generate_secret)
    UID_ENCRYPTION_KEY=$(generate_secret)
    SECRET_ENCRYPTION_KEY=$(generate_aes_key)

    cd /opt || exit

    git clone "$REPO_URL" "$APP_NAME"

    cd "$APP_DIR" || exit

    cat > .env <<EOF
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
UID_ENCRYPTION_KEY=${UID_ENCRYPTION_KEY}
SECRET_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY}

HTTP_ADDR=:8080
DATABASE_PATH=data/omepic.db
REDIS_URL=redis://redis:6379/0
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
UID_PREFIX=omeo_
APP_ENV=production
EOF
    docker compose up -d 

    echo
    echo -e "${GREEN}✅ OmePic 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:${APP_PORT}/admin${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${PUBLIC_BASE_URL}/admin${RESET}"
    echo -e "${YELLOW}🔑 密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${YELLOW}🔑 JWT_SECRET: ${JWT_SECRET}${RESET}"
    echo -e "${YELLOW}📂 安装目录: ${APP_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    git pull
    docker compose up -d 

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return
    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {

    cd "$APP_DIR" || return
    docker compose ps

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
