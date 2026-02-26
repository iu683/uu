#!/bin/bash
# ========================================
# sub2api 企业级一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

APP_NAME="sub2api"
APP_DIR="/opt/sub2api-deploy"
COMPOSE_FILE="$APP_DIR/docker-compose.local.yml"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

# ==============================
# 初始化 compose 命令（关键修复）
# ==============================
init_compose() {

    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}未检测到 docker compose${RESET}"
        exit 1
    fi
}

pause(){
    read -p "按回车返回菜单..."
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${BLUE}=== sub2api 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}7) 查看管理员密码${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            7) show_admin_password ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 功能函数
# ==============================

install_app() {

    init_compose

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    echo -e "${GREEN}正在下载官方部署脚本...${RESET}"
    curl -sSL https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-deploy.sh | bash

    $COMPOSE_CMD -f docker-compose.local.yml up -d

    echo
    echo -e "${GREEN}✅ sub2api 已启动${RESET}"
    echo -e "${GREEN}🌐 WebUI: http://${SERVER_IP}:8080${RESET}"
    echo -e "${GREEN}🌐 账号: admin@sub2api.local${RESET}"
    echo -e "${GREEN}🌐 密码: 7查看管理员密码${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    pause
}

update_app() {

    init_compose
    cd "$APP_DIR" || { echo "未检测到安装目录"; pause; return; }

    $COMPOSE_CMD -f docker-compose.local.yml pull
    $COMPOSE_CMD -f docker-compose.local.yml up -d --remove-orphans

    echo -e "${GREEN}✅ sub2api 更新完成${RESET}"
    pause
}

restart_app() {

    init_compose
    cd "$APP_DIR" || return

    $COMPOSE_CMD -f docker-compose.local.yml restart

    echo -e "${GREEN}✅ sub2api 已重启${RESET}"
    pause
}

view_logs() {

    init_compose
    cd "$APP_DIR" || return

    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    $COMPOSE_CMD -f docker-compose.local.yml logs -f
}

check_status() {

    if docker ps --format '{{.Names}}' | grep -q "^sub2api"; then
        echo -e "${GREEN}sub2api 服务运行中${RESET}"
    else
        echo -e "${RED}sub2api 服务未运行${RESET}"
    fi
    pause
}

show_admin_password() {

    init_compose
    cd "$APP_DIR" || return

    echo -e "${BLUE}正在查找管理员密码...${RESET}"

    PASSWORD=$($COMPOSE_CMD -f docker-compose.local.yml logs sub2api 2>/dev/null \
        | grep -i "admin password" \
        | tail -n 1 \
        | awk -F': ' '{print $NF}')

    if [ -z "$PASSWORD" ]; then
        echo -e "${YELLOW}未找到自动生成的管理员密码${RESET}"
    else
        echo -e "${GREEN}🔐 管理员密码: $PASSWORD${RESET}"
    fi

    pause
}

uninstall_app() {

    init_compose

    echo -e "${YELLOW}正在停止并删除容器...${RESET}"

    # 强制删除容器
    docker rm -f sub2api 2>/dev/null

    # compose down
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$APP_DIR"
        $COMPOSE_CMD -f docker-compose.local.yml down -v --remove-orphans 2>/dev/null
    fi

    # 删除网络（防残留）
    docker network prune -f 2>/dev/null

    # 删除目录
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ sub2api 已彻底卸载${RESET}"
    pause
}

menu
