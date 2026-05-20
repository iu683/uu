#!/bin/bash
# ========================================
# S-UI 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="s-ui"
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

        echo -e "${GREEN}=== S-UI 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/db"
    mkdir -p "$APP_DIR/cert"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入面板端口 [默认:2095]: " input_panel_port
    PANEL_PORT=${input_panel_port:-2095}

    check_port "$PANEL_PORT" || return

    read -p "请输入订阅端口 [默认:2096]: " input_node_port
    NODE_PORT=${input_node_port:-2096}

    check_port "$NODE_PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  s-ui:
    image: alireza7/s-ui
    container_name: s-ui
    hostname: "s-ui"

    volumes:
      - "./db:/app/db"
      - "./cert:/app/cert"

    tty: true

    restart: unless-stopped

    ports:
      - "${PANEL_PORT}:2095"
      - "${NODE_PORT}:2096"

    networks:
      - s-ui

    entrypoint: "./entrypoint.sh"

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  s-ui:
    driver: bridge
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ S-UI 已启动${RESET}"
    echo -e "${YELLOW}🌐 面板地址: http://${SERVER_IP}:${PANEL_PORT}/app/${RESET}"
    echo -e "${YELLOW}🔌 节点端口: ${NODE_PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: $APP_DIR/db${RESET}"
    echo -e "${YELLOW}🔐 证书目录: $APP_DIR/cert${RESET}"
    echo -e "${YELLOW}🔒 面板证书设置: /app/cert/cert.crt${RESET}"
    echo -e "${YELLOW}📂 面板证书设置: /app/cert/private.key${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart s-ui

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f s-ui
}

check_status() {

    docker ps | grep s-ui

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
