#!/bin/bash
# ========================================
# Webtop-Ubuntu 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="webtop-ubuntu"
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
        echo -e "${GREEN}=== Webtop-Ubuntu 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/config"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3006]: " input_port
    PORT=${input_port:-3006}
    check_port "$PORT" || return

    read -p "请输入用户名 [默认:admin]: " username
    CUSTOM_USER=${username:-admin}

    read -p "请输入密码 [默认:changeme]: " passwd
    PASSWORD=${passwd:-changeme}

    TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ -z "$TIMEZONE" ] && TIMEZONE="Asia/Shanghai"

    cat > "$COMPOSE_FILE" <<EOF
services:
  webtop-ubuntu:
    image: lscr.io/linuxserver/webtop:ubuntu-kde
    container_name: webtop-ubuntu
    security_opt:
      - seccomp:unconfined
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TIMEZONE}
      - SUBFOLDER=/
      - TITLE=Webtop
      - CUSTOM_USER=${CUSTOM_USER}
      - PASSWORD=${PASSWORD}
      - LC_ALL=zh_CN.UTF-8
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - ./config:/config
      - /var/run/docker.sock:/var/run/docker.sock
    devices:
      - /dev/dri:/dev/dri
    shm_size: 2gb
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Webtop-Ubuntu 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}👤 用户名: ${CUSTOM_USER}  🔑 密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Webtop-Ubuntu 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart webtop-ubuntu
    echo -e "${GREEN}✅ Webtop-Ubuntu 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f webtop-ubuntu
}

check_status() {
    docker ps | grep webtop-ubuntu
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Webtop-Ubuntu 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
