#!/bin/bash
# ========================================
# AdGuardHome 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="adguardhome"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
    if ss -tuln | grep -q ":$1 "; then
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
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== AdGuardHome 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    echo -e "${GREEN}请输入 Web 管理端口${RESET}"
    read -p "默认 [3000]: " input_web
    WEB_PORT=${input_web:-3000}
    check_port "$WEB_PORT" || return
  
    echo
    read -p "请输入工作目录 [默认:$APP_DIR/workdir]: " input_work
    WORK_DIR=${input_work:-$APP_DIR/workdir}

    read -p "请输入配置目录 [默认:$APP_DIR/confdir]: " input_conf
    CONF_DIR=${input_conf:-$APP_DIR/confdir}

    mkdir -p "$WORK_DIR"
    mkdir -p "$CONF_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: always
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "${WEB_PORT}:3000/tcp"
    volumes:
      - ${WORK_DIR}:/opt/adguardhome/work
      - ${CONF_DIR}:/opt/adguardhome/conf
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ AdGuardHome 已启动${RESET}"
    echo -e "${YELLOW}🌐 管理地址: http://${SERVER_IP}:${WEB_PORT}${RESET}"
    echo -e "${GREEN}📂 Work目录: ${WORK_DIR}${RESET}"
    echo -e "${GREEN}📂 Config目录: ${CONF_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ AdGuardHome 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart adguardhome
    echo -e "${GREEN}✅ AdGuardHome 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f adguardhome
}

check_status() {
    docker ps | grep adguardhome
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ AdGuardHome 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
