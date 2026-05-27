#!/bin/bash
# ========================================
# EasyTier 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="easytier"
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

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== EasyTier 管理菜单 ===${RESET}"
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

    mkdir -p /etc/easytier
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -ne "${YELLOW}检测到已安装，是否覆盖安装？(y/n): ${RESET}"
        read -r confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo

    read -p "请输入服务器地址: " SERVER_ADDR
    read -p "请输入网络名称 Network Name: " NETWORK_NAME
    read -p "请输入网络密码 Network Secret: " NETWORK_SECRET
    read -p "请输入端口 [默认:11010]: " input_port

    SERVER_ADDR=$(echo "$SERVER_ADDR" | xargs)
    NETWORK_NAME=$(echo "$NETWORK_NAME" | xargs)
    NETWORK_SECRET=$(echo "$NETWORK_SECRET" | xargs)
    PORT=${input_port:-11010}

    cat > "$COMPOSE_FILE" <<EOF
services:
  easytier:
    image: easytier/easytier:latest
    pull_policy: always
    container_name: easytier
    hostname: easytier
    restart: always
    privileged: true
    network_mode: host

    volumes:
      - /etc/easytier:/root

    environment:
      - TZ=Asia/Shanghai

    command: >
      -i ${SERVER_ADDR}
      --network-name "${NETWORK_NAME}"
      --network-secret "${NETWORK_SECRET}"
      -e tcp://${SERVER_ADDR}:${PORT}
      -l tcp://${SERVER_ADDR}:${PORT}

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF


    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ EasyTier 已启动${RESET}"
    echo -e "${YELLOW}🌐 网络名称: ${NETWORK_NAME}${RESET}"
    echo -e "${YELLOW}🌐 网络密码: ${NETWORK_SECRET}${RESET}"
    echo -e "${YELLOW}📡 服务器: ${SERVER_ADDR}:${PORT}${RESET}"
    echo -e "${YELLOW}📂 配置目录: /etc/easytier${RESET}"

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

    docker restart easytier

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f easytier
}

check_status() {

    docker ps | grep easytier

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v
    rm -rf "$APP_DIR"
    rm -rf /etc/easytier

    echo -e "${RED}✅ 已卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
