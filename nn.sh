#!/bin/bash
# ========================================
# Codex WebUI 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="codex-webui"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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

generate_key() {

    openssl rand -hex 32
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== Codex WebUI 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入服务端口 [默认:8172]: " input_port
    PORT=${input_port:-8172}

    check_port "$PORT" || return

    WEBUI_API_KEY=$(generate_key)

    echo
    read -p "请输入 OPENAI_API_KEY [可留空]: " OPENAI_API_KEY

    cat > "$ENV_FILE" <<EOF
PORT=${PORT}
WEBUI_API_KEY=${WEBUI_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  codex-webui:
    image: ghcr.io/limlll/codex-webui:latest

    container_name: codex-webui

    ports:
      - "127.0.0.1:\${PORT:-8172}:8172"

    environment:
      NODE_ENV: production
      PORT: 8172
      WEBUI_API_KEY: \${WEBUI_API_KEY}
      WORKSPACE_ROOTS: /workspaces
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}

    volumes:
      - root_home:/root
      - workspaces:/workspaces

    cap_add:
      - SYS_ADMIN

    security_opt:
      - apparmor:unconfined
      - seccomp:unconfined

    restart: unless-stopped

    env_file:
      - .env

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  root_home:
  workspaces:
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Codex WebUI 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔑 WEBUI_API_KEY: ${WEBUI_API_KEY}${RESET}"
    echo -e "${YELLOW}⚙️ 环境文件: $ENV_FILE${RESET}"

    if [ -n "$OPENAI_API_KEY" ]; then
        echo -e "${GREEN}✅ 已配置 OPENAI_API_KEY${RESET}"
    fi

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

    docker restart codex-webui

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f codex-webui
}

check_status() {

    docker ps | grep codex-webui

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
