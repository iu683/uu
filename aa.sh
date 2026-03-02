#!/bin/bash
# ========================================
# AnyTLS 一键管理脚本（Host模式）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="anytls-server"
APP_DIR="/root/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="anytls-server"

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
    if ss -tulnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

SERVER_IP=$(hostname -I | awk '{print $1}')

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== AnyTLS 管理菜单 ===${RESET}"
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

    # 端口
    read -p "请输入监听端口 [默认随机]: " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 1025-65535 -n1)
    else
        PORT=$input_port
    fi

    check_port "$PORT" || return

    # 随机密码
    MIMA=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    # 生成 compose
    cat > "$COMPOSE_FILE" <<EOF
services:
  anytls-server:
    image: jonnyan404/anytls
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: host
    environment:
      TZ: Asia/Shanghai
      PORT: "${PORT}"
      MIMA: "${MIMA}"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo
    echo -e "${GREEN}✅ AnyTLS 已启动${RESET}"
    echo -e "${YELLOW}🌐 公网 IP: ${SERVER_IP}${RESET}"
    echo -e "${YELLOW}🔌 端口: ${PORT}${RESET}"
    echo -e "${YELLOW}🔑 密码: ${MIMA}${RESET}"
    echo
    echo -e "${GREEN}📄 客户端信息:${RESET}"
    echo -e "${YELLOW}V2rayN: anytls://${MIMA}@${SERVER_IP}:${PORT}/?insecure=1#$HOSTNAME"
    echo -e "${YELLOW}Surge : $HOSTNAME = anytls, ${SERVER_IP}, ${PORT}, password=${MIMA}, tfo=true, skip-cert-verify=true, reuse=false"
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
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ 已重启${RESET}"
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
    docker stop ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
