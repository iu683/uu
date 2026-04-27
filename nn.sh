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

REPO="https://github.com/your-username/forwardx.git"

function menu() {
    clear
    echo -e "${GREEN}=== ForwardX 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) uninstall_app ;;
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

    # 默认值处理
    [ -z "$JWT_SECRET" ] && JWT_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
    [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD="admin123"

    # 生成 .env
    cat > .env <<EOF
# ==================== 数据库配置 ====================
SQLITE_PATH=/data/forwardx.db

# ==================== 安全配置 ====================
JWT_SECRET=$JWT_SECRET

# ==================== 应用配置 ====================
NODE_ENV=production
PORT=3000

# ==================== 默认管理员账户 ====================
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF

    echo -e "${GREEN}配置生成完成${RESET}"
    echo -e "JWT_SECRET=$JWT_SECRET"
    echo -e "ADMIN_PASSWORD=$ADMIN_PASSWORD"

    echo -e "${GREEN}启动服务...${RESET}"
    docker compose up -d

    echo
    echo -e "${GREEN}✅ ForwardX 已启动${RESET}"
    echo -e "${YELLOW}访问: http://localhost:3000${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${GREEN}更新程序...${RESET}"

    git pull
    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ ForwardX 已更新${RESET}"

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

function view_logs() {

    docker logs -f forwardx

    read -p "按回车返回菜单..."
    menu
}

menu
