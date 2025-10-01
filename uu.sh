#!/bin/bash
# ======================================
# MTProxy 一键管理脚本 (Docker)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mtproxy"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== MTProxy 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR"
    read -rp "请输入域名 [默认: cloudflare.com]: " domain
    domain=${domain:-cloudflare.com}

    read -rp "请输入 MTProxy secret (回车自动生成随机32字符): " secret
    if [[ -z "$secret" ]]; then
        secret=$(openssl rand -hex 16)  # 16字节十六进制 => 32字符
        echo "已生成随机 secret: $secret"
    fi

    read -rp "是否启用 IP 白名单 (ON/OFF) [默认: OFF]: " ip_white
    ip_white=${ip_white:-OFF}
    read -rp "HTTP 端口 [默认:8080]: " http_port
    http_port=${http_port:-8080}
    read -rp "HTTPS 端口 [默认:8443]: " https_port
    https_port=${https_port:-8443}

    cat > "$COMPOSE_FILE" <<EOF
services:
  mtproxy:
    container_name: mtproxy
    image: ellermister/mtproxy:latest
    restart: always
    environment:
      - domain=${domain}
      - secret=${secret}
      - ip_white_list=${ip_white}
    ports:
      - "${http_port}:80"
      - "${https_port}:443"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(get_ip)
    SECRET=$(docker logs --tail 50 ${NAME} 2>&1 | grep "MTProxy Secret" | awk '{print $NF}' | tail -n1)

    echo -e "${GREEN}✅ MTProxy 已启动${RESET}"
    echo -e "${YELLOW}HTTP 端口: $http_port${RESET}"
    echo -e "${YELLOW}HTTPS 端口: $https_port${RESET}"
    echo -e "${GREEN}👉 Telegram 链接：日志查看将端口替换为$https_port即可${RESET}"
    echo -e "${GREEN}📂 数据目录: /opt/mtproxy${RESET}"
    read -rp "按回车返回菜单..."
    menu
}


update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MTProxy 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MTProxy 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f mtproxy
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
