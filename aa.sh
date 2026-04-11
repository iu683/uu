#!/bin/bash
# ========================================
# Glash 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="glash"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_DIR="$APP_DIR/config"

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

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
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
        echo -e "${GREEN}=== Glash 管理菜单 ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR" "$CONFIG_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 HTTP 代理端口 [默认:7890]: " input_http_port
    HTTP_PORT=${input_http_port:-7890}
    check_port "$HTTP_PORT" || return

    read -p "请输入 SOCKS5 代理端口 [默认:7891]: " input_socks_port
    SOCKS_PORT=${input_socks_port:-7891}
    check_port "$SOCKS_PORT" || return

    read -p "请输入 Dashboard 端口 [默认:9090]: " input_dashboard_port
    DASHBOARD_PORT=${input_dashboard_port:-9090}
    check_port "$DASHBOARD_PORT" || return

    read -p "请输入订阅地址 SUB_URL: " SUB_URL
    if [ -z "$SUB_URL" ]; then
        echo -e "${RED}SUB_URL 不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    read -p "请输入 Dashboard 密码 SECRET: " SECRET
    if [ -z "$SECRET" ]; then
        echo -e "${RED}SECRET 不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    read -p "请输入订阅更新 CRON [默认:0 */6 * * *]: " input_cron
    SUB_CRON=${input_cron:-0 */6 * * *}

    read -p "是否允许局域网访问 ALLOW_LAN [默认:true]: " input_allow_lan
    ALLOW_LAN=${input_allow_lan:-true}

    cat > "$COMPOSE_FILE" <<EOF
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: always
    ports:
      - '${HTTP_PORT}:7890'
      - '${SOCKS_PORT}:7891'
      - '127.0.0.1:${DASHBOARD_PORT}:9090'
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
      - SUB_URL=${SUB_URL}
      - SUB_CRON=${SUB_CRON}
      - SECRET=${SECRET}
      - ALLOW_LAN=${ALLOW_LAN}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Glash 已启动${RESET}"
    echo -e "${YELLOW}🌐 HTTP 代理:  http://127.0.0.1:${HTTP_PORT}${RESET}"
    echo -e "${YELLOW}🌐 SOCKS5 代理: socks5://${SERVER_IP}:${SOCKS_PORT}${RESET}"
    echo -e "${YELLOW}⚙️ Dashboard:  http://${SERVER_IP}:${DASHBOARD_PORT}${RESET}"
    echo -e "${YELLOW}⚙️ 密码:  ${SECRET}${RESET}"
    echo -e "${GREEN}📂 配置目录: ${CONFIG_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Glash 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart glash
    echo -e "${GREEN}✅ Glash 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f glash
}

check_status() {
    docker ps | grep glash
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Glash 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
