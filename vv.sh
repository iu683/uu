#!/bin/bash
# ========================================
# WUD 一键管理脚本（自动生成密码 Hash）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="wud"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="wud"

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

install_htpasswd() {
    if ! command -v htpasswd &>/dev/null; then
        echo -e "${YELLOW}未检测到 htpasswd 命令，正在安装...${RESET}"
        if [ -f /etc/debian_version ]; then
            sudo apt update
            sudo apt install apache2-utils -y
        elif [ -f /etc/redhat-release ]; then
            sudo yum install httpd-tools -y
        else
            echo -e "${RED}无法自动安装 htpasswd，请手动安装 apache2-utils/httpd-tools${RESET}"
            exit 1
        fi
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
        echo -e "${GREEN}=== WUD 管理菜单 ===${RESET}"
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
    install_htpasswd
    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3001]: " input_port
    PORT=${input_port:-3001}
    check_port "$PORT" || return

    read -p "请输入 WUD 管理员用户名 [默认:admin]: " username
    USERNAME=${username:-admin}
    read -s -p "请输入 WUD 密码 [默认:123456]: " password
    PASSWORD=${password:-123456}
    echo

    # 生成 htpasswd hash 并替换 $ 为 $$
    HASH=$(htpasswd -nbB "$USERNAME" "$PASSWORD" | cut -d: -f2 | sed 's/\$/\$\$/g')

    cat > "$COMPOSE_FILE" <<EOF
services:
  whatsupdocker:
    image: getwud/wud
    container_name: ${CONTAINER_NAME}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - WUD_AUTH_BASIC_ADMIN_USER=${USERNAME}
      - WUD_AUTH_BASIC_ADMIN_HASH=${HASH}
    restart: always
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ WUD 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔑 用户名: ${USERNAME}  密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ WUD 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart ${CONTAINER_NAME}
    echo -e "${GREEN}✅ WUD 已重启${RESET}"
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
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ WUD 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
