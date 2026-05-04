#!/bin/bash
# ========================================
# Zephyr SSH 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="zephyr-ssh"
APP_DIR="/opt/$APP_NAME"

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
    echo -e "${GREEN}=== Zephyr SSH 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/zephyr-data"
    cd "$APP_DIR" || exit

    echo -e "${GREEN}配置端口...${RESET}"

    read -p "请输入访问端口 [默认:3000]: " PORT
    [ -z "$PORT" ] && PORT=3000

    # 检查端口是否占用
    if ss -tuln | grep -q ":$PORT "; then
        echo -e "${RED}端口 $PORT 已被占用！${RESET}"
        read -p "按回车返回菜单..."
        menu
        return
    fi

    read -p "请输入访问域名(例如 https://ssh.example.com): " DOMAIN

    ENCRYPTION_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

    SERVER_IP=$(get_public_ip)
    [ -z "$DOMAIN" ] && DOMAIN="http://127.0.0.1:${PORT}"

    cat > ./zephyr-data/.env <<EOF
ENCRYPTION_KEY=$ENCRYPTION_KEY
PUBLIC_ORIGIN=$DOMAIN
PORT=3000
EOF

    cat > docker-compose.yml <<EOF
services:
  zephyr-ssh:
    container_name: zephyr-ssh
    env_file:
      - ./zephyr-data/.env
    ports:
      - 127.0.0.1:${PORT}:3000
    volumes:
      - ./zephyr-data:/app/data
    restart: unless-stopped
    image: ghcr.io/lanlan13-14/zephyr-ssh:latest
EOF

    echo -e "${GREEN}启动服务...${RESET}"
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Zephyr SSH 已启动${RESET}"
    echo -e "${YELLOW}访问地址: $DOMAIN${RESET}"
    echo -e "${YELLOW}密钥: $ENCRYPTION_KEY${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {

    cd "$APP_DIR" || { echo "未安装"; sleep 1; menu; }

    echo -e "${GREEN}拉取最新镜像...${RESET}"
    docker compose pull
    docker compose up -d

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
    docker ps | grep zephyr-ssh

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
