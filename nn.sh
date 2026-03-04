#!/bin/bash
# ========================================
# H UI 一键管理脚本（Host模式）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="h-ui"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="h-ui"

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
    echo "无法获取公网 IP 地址。"
}


menu() {
    while true; do
        clear
        echo -e "${GREEN}=== H-UI 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/my_acme_dir"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入面板端口 [默认8081]: " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-8081}

    mkdir -p "$APP_DIR"/{bin,data,export,logs}

    cat > "$COMPOSE_FILE" <<EOF
services:
  h-ui:
    image: jonssonyan/h-ui
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - $APP_DIR/bin:/h-ui/bin
      - $APP_DIR/data:/h-ui/data
      - $APP_DIR/export:/h-ui/export
      - $APP_DIR/logs:/h-ui/logs
      - $APP_DIR/my_acme_dir:/h-ui/my_acme_dir
    command: ./h-ui -p ${PANEL_PORT}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ H-UI 已启动${RESET}"
    echo -e "${YELLOW}🌐 公网 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 面板端口: ${PANEL_PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR${RESET}"
    echo -e "${YELLOW}📜 证书目录: $APP_DIR/my_acme_dir${RESET}"
    echo -e "${YELLOW}✅ 登录用户名/密码: sysadmin/sysadmin${RESET}"
    echo -e "${YELLOW}✅ 连接密码: sysadmin.sysadmin${RESET}"
    echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${PANEL_PORT}${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ H-UI更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ H-UI已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f ${CONTAINER_NAME}
}

check_status() {
    docker ps | grep ${CONTAINER_NAME}
    read -p "按回车返回菜单..."
}

uninstall_app() {
    docker compose -f ${COMPOSE_FILE} down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ H-UI已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
