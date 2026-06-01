#!/bin/bash
# ========================================
# NetCenter 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="netcenter"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

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

        echo -e "${GREEN}=== NetCenter 管理菜单 ===${RESET}"
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

    echo
    read -p "监听端口 [默认:8055]: " input_port
    PORT=${input_port:-8055}
    check_port "$PORT" || return

    read -p "登录用户名 [默认:admin]: " input_user
    USERNAME=${input_user:-admin}

    DEFAULT_PASS=$(generate_password)
    read -p "登录密码 [默认随机生成]: " input_pass
    PASSWORD=${input_pass:-$DEFAULT_PASS}

    read -p "监听地址 [默认:127.0.0.1]: " input_host
    HOST=${input_host:-127.0.0.1}

    read -p "监控网卡 [留空自动检测]: " IFACE

    cat > "$COMPOSE_FILE" <<EOF
services:
  netcenter:
    image: ghcr.io/xx2468171796/netcenter:latest

    container_name: netcenter

    restart: unless-stopped

    pid: host
    network_mode: host

    cap_add:
      - SYS_PTRACE

    environment:
      HOST_PROC: /host/proc
      HOST_ROOT: /host
      SM_PORT: ${PORT}
      SM_HOST: ${HOST}
      SM_USER: ${USERNAME}
      SM_PASS: ${PASSWORD}
      $( [ -n "$IFACE" ] && echo "SM_IFACE: ${IFACE}" )

    volumes:
      - /proc:/host/proc:ro
      - /:/host:ro,rslave
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - netcenter-data:/app/data
      - netcenter-vnstat:/var/lib/vnstat

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  netcenter-data:
  netcenter-vnstat:
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ NetCenter 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${HOST}:${PORT}${RESET}"
    echo -e "${YELLOW}👤 用户名: ${USERNAME}${RESET}"
    echo -e "${YELLOW}🔐 密码: ${PASSWORD}${RESET}"
    echo -e "${YELLOW}📂 安装目录: ${APP_DIR}${RESET}"

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

    docker restart netcenter

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f netcenter
}

check_status() {

    docker ps | grep netcenter

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
