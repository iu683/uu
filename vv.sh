#!/bin/bash
# ========================================
# 思源笔记 Docker 一键管理脚本 Pro
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="siyuan"
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

get_timezone() {
    if command -v timedatectl &>/dev/null; then
        timedatectl show -p Timezone --value 2>/dev/null
    elif [[ -f /etc/timezone ]]; then
        cat /etc/timezone
    else
        echo "Asia/Tokyo"
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 思源笔记 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/workspace"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:6806]: " input_port
    PORT=${input_port:-6806}
    check_port "$PORT" || return

    TIMEZONE=$(get_timezone)

    # 认证码设置
    read -p "请输入访问认证码 [留空自动生成]: " input_auth
    if [ -z "$input_auth" ]; then
        AUTH_CODE=$(openssl rand -hex 8)
        echo -e "${YELLOW}未输入认证码，已自动生成${RESET}"
    else
        AUTH_CODE="$input_auth"
    fi

    echo "AuthCode=${AUTH_CODE}" > "$ENV_FILE"
    echo "YOUR_TIME_ZONE=${TIMEZONE}" >> "$ENV_FILE"
    echo "PORT=${PORT}" >> "$ENV_FILE"

    cat > "$COMPOSE_FILE" <<EOF
services:
  main:
    image: b3log/siyuan
    container_name: siyuan
    command: ['--workspace=/siyuan/workspace/', '--accessAuthCode=\${AuthCode}']
    ports:
      - "127.0.0.1:\${PORT}:6806"
    volumes:
      - ./workspace:/siyuan/workspace
    restart: unless-stopped
    environment:
      - TZ=\${YOUR_TIME_ZONE}
      - PUID=1000
      - PGID=1000
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ 思源笔记 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔐 访问认证码: ${AUTH_CODE}${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"

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
    docker restart siyuan
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f siyuan
}

check_status() {
    docker ps | grep siyuan
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" 2>/dev/null || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ 已卸载（数据已删除）${RESET}"
    read -p "按回车返回菜单..."
}

menu
