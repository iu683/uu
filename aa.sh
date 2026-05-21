#!/bin/bash
# ========================================
# Xboard-Node 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="xboard-node"
APP_DIR="/opt/$APP_NAME"

CONFIG_FILE="$APP_DIR/config.yml"
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

        echo -e "${GREEN}=== Xboard-Node 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 停止${RESET}"
        echo -e "${GREEN}5) 查看日志${RESET}"
        echo -e "${GREEN}6) 查看状态${RESET}"
        echo -e "${GREEN}7) 修改配置${RESET}"
        echo -e "${GREEN}8) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) stop_app ;;
            5) view_logs ;;
            6) check_status ;;
            7) edit_config ;;
            8) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    mkdir -p "$APP_DIR/certs"

    echo
    read -p "请输入 Xboard 面板地址: " PANEL_URL

    echo
    read -p "请输入通讯 Token: " PANEL_TOKEN

    echo
    read -p "请输入 Node ID: " NODE_ID

    cat > "$CONFIG_FILE" <<EOF
panel:
  url: "$PANEL_URL"
  token: "$PANEL_TOKEN"
  node_id: $NODE_ID

kernel:
  type: "singbox"
  config_dir: "/etc/xboard-node"
  log_level: "warn"

cert:
  cert_mode: "none"

log:
  level: "info"
  output: "stdout"
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  xboard-node:
    image: ghcr.io/cedar2025/xboard-node:latest
    container_name: xboard-node
    restart: always
    network_mode: host

    volumes:
      - ./config.yml:/etc/xboard-node/config.yml
      - ./certs:/etc/xboard-node/certs
EOF

    cd "$APP_DIR" || exit

    echo
    echo -e "${GREEN}启动 Xboard-Node...${RESET}"

    docker compose pull

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Xboard-Node 已启动${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"

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

    cd "$APP_DIR" || return

    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

stop_app() {

    cd "$APP_DIR" || return

    docker compose down

    echo -e "${YELLOW}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return

    docker logs -f xboard-node
}

check_status() {

    cd "$APP_DIR" || return

    docker compose ps

    read -p "按回车返回菜单..."
}

edit_config() {

    nano "$CONFIG_FILE"

    cd "$APP_DIR" || return

    docker compose restart

    echo -e "${GREEN}✅ 配置已更新并重启${RESET}"

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
