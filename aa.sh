#!/bin/bash
# ========================================
# Hermes WebUI 一键管理脚本
# 直接使用官方镜像版
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="hermes-webui"
APP_DIR="/opt/$APP_NAME"

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

check_port() {

    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}       Hermes WebUI 管理菜单${RESET}"
        echo -e "${GREEN}========================================${RESET}"

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

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8787]: " input_port
    PORT=${input_port:-8787}
    check_port "$PORT" || return

    read -p "请输入 WebUI 登录密码 [默认:admin123]: " input_pass
    WEB_PASSWORD=${input_pass:-admin123}

    read -p "请输入工作目录 [默认:$HOME/workspace]: " input_workspace
    WORKSPACE_DIR=${input_workspace:-$HOME/workspace}

    mkdir -p "$WORKSPACE_DIR"
    mkdir -p "$HOME/.hermes"

    cat > "$ENV_FILE" <<EOF
UID=$(id -u)
GID=$(id -g)

HERMES_HOME=$HOME/.hermes
HERMES_WORKSPACE=$WORKSPACE_DIR

HERMES_WEBUI_PASSWORD=$WEB_PASSWORD

HERMES_SKIP_CHMOD=1
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  hermes-webui:
    image: ghcr.io/nesquena/hermes-webui:latest
    container_name: hermes-webui

    ports:
      - "127.0.0.1:${PORT}:8787"

    volumes:
      - \${HERMES_HOME:-\${HOME}/.hermes}:/home/hermeswebui/.hermes
      - \${HERMES_WORKSPACE:-\${HOME}/workspace}:/workspace

    environment:
      - WANTED_UID=\${UID:-1000}
      - WANTED_GID=\${GID:-1000}

      - HERMES_WEBUI_HOST=0.0.0.0
      - HERMES_WEBUI_PORT=8787

      - HERMES_WEBUI_STATE_DIR=/home/hermeswebui/.hermes/webui

      - HERMES_WEBUI_PASSWORD=\${HERMES_WEBUI_PASSWORD}

      - HERMES_SKIP_CHMOD=1

    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}✅ Hermes WebUI 安装完成${RESET}"
    echo -e "${GREEN}========================================${RESET}"

    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔐 登录密码: ${WEB_PASSWORD}${RESET}"
    echo -e "${YELLOW}📂 Hermes 数据目录: $HOME/.hermes${RESET}"
    echo -e "${YELLOW}📂 工作目录: $WORKSPACE_DIR${RESET}"

    echo

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Hermes WebUI 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart hermes-webui

    echo -e "${GREEN}✅ Hermes WebUI 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f hermes-webui
}

check_status() {

    docker ps --filter "name=hermes-webui"

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    docker compose down -v

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Hermes WebUI 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
