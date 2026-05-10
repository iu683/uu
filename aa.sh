#!/bin/bash
# ========================================
# LiteGist 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="litegist"
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

menu() {
    while true; do
        clear

        echo -e "${GREEN}=== LiteGist 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR/data"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:3382]: " input_port
    PORT=${input_port:-3382}
    check_port "$PORT" || return

    read -p "请输入管理员用户名 [默认:admin]: " input_user
    ADMIN_USER=${input_user:-admin}

    read -p "请输入管理员密码 [默认:随机生成]: " input_pass

    if [ -z "$input_pass" ]; then
        ADMIN_PASS=$(openssl rand -hex 8)
    else
        ADMIN_PASS="$input_pass"
    fi

    read -p "请输入 API_KEY [默认:随机生成]: " input_key

    if [ -z "$input_key" ]; then
        API_KEY=$(openssl rand -hex 16)
    else
        API_KEY="$input_key"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  litegist:
    image: lockcp/litegist:latest
    container_name: litegist
    restart: unless-stopped

    ports:
      - "127.0.0.1:${PORT}:3382"

    volumes:
      - ./data:/app/data

    environment:
      PORT: 3382
      ADMIN_USERNAME: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASS}
      API_KEY: ${API_KEY}
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    cat > "$APP_DIR/account.txt" <<EOF
访问地址:
http://127.0.0.1:${PORT}

管理员账号:
${ADMIN_USER}

管理员密码:
${ADMIN_PASS}

API_KEY:
${API_KEY}
EOF

    echo
    echo -e "${GREEN}✅ LiteGist 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://127.0.0.1:${PORT}"
    echo -e "${GREEN}👤 用户名:${RESET} ${ADMIN_USER}"
    echo -e "${GREEN}🔑 密码:${RESET} ${ADMIN_PASS}"
    echo -e "${GREEN}🗝 API_KEY:${RESET} ${API_KEY}"
    echo -e "${GREEN}📄 已保存到:${RESET} $APP_DIR/account.txt"

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

    docker restart litegist

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f litegist
}

check_status() {

    docker ps | grep litegist

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
