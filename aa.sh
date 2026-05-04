#!/bin/bash
# ========================================
# TGState 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="tgstate"
APP_DIR="/opt/$APP_NAME"

REPO="https://github.com/buyi06/tgstate-rust.git"

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "0.0.0.0"
}

menu() {
    clear
    echo -e "${GREEN}=== TGState 管理菜单 ===${RESET}"
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

    echo -e "${GREEN}配置端口...${RESET}"

    read -p "请输入访问端口 [默认:8000]: " PORT
    [ -z "$PORT" ] && PORT=8000

    # 检查端口占用
    if ss -tuln | grep -q ":$PORT "; then
        echo -e "${RED}端口 $PORT 已被占用！${RESET}"
        read -p "按回车返回菜单..."
        menu
        return
    fi

    cat > docker-compose.yml <<EOF
services:
  tgstate:
    build: .
    ports:
      - "127.0.0.1:${PORT}:8000"
    volumes:
      - tgstate_data:/app/data
    restart: unless-stopped

volumes:
  tgstate_data:
EOF

    echo -e "${GREEN}构建并启动（首次会较慢）...${RESET}"
    docker compose up -d --build

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ TGState 已启动${RESET}"
    echo -e "${YELLOW}访问: http://127.0.0.1:${PORT}${RESET}"

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

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

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
    docker ps | grep tgstate

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
