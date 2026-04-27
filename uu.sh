#!/bin/bash
# ========================================
# ForwardX 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="forwardx"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="forwardx"

REPO="https://github.com/poouo/Forwardx.git"

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

function menu() {
    clear
    echo -e "${GREEN}=== ForwardX 管理菜单 ===${RESET}"
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

function install_app() {

    echo -e "${GREEN}正在检查/安装 Docker...${RESET}"

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
    echo -e "${GREEN}生成配置文件...${RESET}"

    read -p "请输入 JWT_SECRET (留空自动生成): " JWT_SECRET
    read -p "请输入 ADMIN_PASSWORD (留空默认 admin123): " ADMIN_PASSWORD

    [ -z "$JWT_SECRET" ] && JWT_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
    [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD="admin123"

    cat > .env <<EOF
SQLITE_PATH=/data/forwardx.db
JWT_SECRET=$JWT_SECRET
NODE_ENV=production
PORT=3000
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF

    echo -e "${GREEN}配置生成完成${RESET}"
    echo -e "JWT_SECRET=$JWT_SECRET"
    echo -e "ADMIN_PASSWORD=$ADMIN_PASSWORD"

    echo -e "${GREEN}启动服务...${RESET}"
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ ForwardX 已启动${RESET}"
    echo -e "${YELLOW}访问: http://${SERVER_IP}:3000${RESET}"
    echo -e "${YELLOW}账号: admin${RESET}"
    echo -e "${YELLOW}密码: $ADMIN_PASSWORD${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${GREEN}更新程序...${RESET}"

    git pull

    echo -e "${GREEN}重新构建镜像...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ ForwardX 已更新并重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function restart_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${GREEN}正在重启...${RESET}"
    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {

    docker logs -f forwardx-panel

    read -p "按回车返回菜单..."
    menu
}

function check_status() {

    echo -e "${GREEN}容器状态：${RESET}"
    docker ps | grep forwardx

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ ForwardX 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

menu
