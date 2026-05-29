#!/bin/bash
# ========================================
# OneFile 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="onefile"
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

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== OneFile 管理菜单 ===${RESET}"
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

    read -p "请输入监听地址 [默认:127.0.0.1]: " input_host
    HOST=${input_host:-127.0.0.1}

    read -p "请输入端口 [默认:27507]: " input_port
    PORT=${input_port:-27507}
    check_port "$PORT" || return

    echo
    read -p "请输入 Github Client ID: " GITHUB_CLIENT_ID
    read -p "请输入 Github Client Secret: " GITHUB_CLIENT_SECRET
    read -p "请输入 APP_ORIGIN [可留空]: " APP_ORIGIN

    APP_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)

    cat > "$ENV_FILE" <<EOF
ONEFILE_HOST=${HOST}
ONEFILE_PORT=${PORT}

APP_SECRET=${APP_SECRET}
APP_ORIGIN=${APP_ORIGIN}

GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID}
GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}

ONEFILE_IMAGE=ghcr.io/zhihui-hu/one-file:latest
ONEFILE_PULL_POLICY=always
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  onefile:
    image: \${ONEFILE_IMAGE:-ghcr.io/zhihui-hu/one-file:latest}

    pull_policy: \${ONEFILE_PULL_POLICY:-always}

    container_name: onefile

    restart: unless-stopped
    init: true

    environment:
      APP_SECRET: \${APP_SECRET:-}
      APP_ORIGIN: \${APP_ORIGIN:-}
      GITHUB_CLIENT_ID: \${GITHUB_CLIENT_ID}
      GITHUB_CLIENT_SECRET: \${GITHUB_CLIENT_SECRET}

    ports:
      - "\${ONEFILE_HOST:-127.0.0.1}:\${ONEFILE_PORT:-27507}:27507"

    volumes:
      - onefile-data:/app/data

    security_opt:
      - no-new-privileges:true

    cap_drop:
      - ALL

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "node -e \\"fetch('http://127.0.0.1:' + (process.env.PORT || 27507) + '/').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\\""
        ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  onefile-data:
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ OneFile 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${HOST}:${PORT}${RESET}"
    echo -e "${YELLOW}GitHub OAuth callback 地址填:${RESET}"
    echo -e "${YELLOW}https://你的域名/callback/auth${RESET}"
    echo -e "${YELLOW}🔐 APP_SECRET: $APP_SECRET ${RESET}"
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

    docker restart onefile

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f onefile
}

check_status() {

    docker ps | grep onefile

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
