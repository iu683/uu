#!/bin/bash
# ========================================
# Emby-In-One 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="emby-in-one"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_DIR="$APP_DIR/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
REPO_URL="https://github.com/ArizeSky/Emby-In-One.git"

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
        echo -e "${GREEN}=== Emby-In-One 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含配置)${RESET}"
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
        rm -rf "$APP_DIR"
        mkdir -p "$APP_DIR"
    fi

    echo -e "${GREEN}开始下载 Emby-In-One...${RESET}"
    git clone "$REPO_URL" "$APP_DIR" || {
        echo -e "${RED}项目克隆失败，请检查网络或 Git 环境${RESET}"
        read -p "按回车返回菜单..."
        return
    }

    mkdir -p "$CONFIG_DIR"

    read -p "请输入服务端口 [默认:8096]: " input_port
    PORT=${input_port:-8096}
    check_port "$PORT" || return

    read -p "请输入站点名称 [默认:Emby-In-One]: " input_name
    SERVER_NAME=${input_name:-Emby-In-One}

    read -p "请输入管理员用户名 [默认:admin]: " input_admin
    ADMIN_USER=${input_admin:-admin}

    read -p "请输入管理员密码: " ADMIN_PASS
    if [ -z "$ADMIN_PASS" ]; then
        echo -e "${RED}管理员密码不能为空${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cat > "$CONFIG_FILE" <<EOF
server:
  port: ${PORT}
  name: "${SERVER_NAME}"

admin:
  username: "${ADMIN_USER}"
  password: "${ADMIN_PASS}"

playback:
  mode: "proxy"

timeouts:
  api: 30000
  global: 15000
  login: 10000
  healthCheck: 10000
  healthInterval: 60000

proxies: []
upstream: []
EOF

    cd "$APP_DIR" || exit

    docker compose build
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Emby-In-One 已启动${RESET}"
    echo -e "${YELLOW}🌐 客户端连接地址: http://${SERVER_IP}:${PORT}${RESET}"
    echo -e "${YELLOW}⚙️ 管理面板地址: http://${SERVER_IP}:${PORT}/admin${RESET}"
    echo -e "${YELLOW}⚙️ 账号: ${ADMIN_USER}${RESET}"
    echo -e "${YELLOW}⚙️ 密码: ${ADMIN_PASS}${RESET}"
    echo -e "${GREEN}📂 配置文件位置: ${CONFIG_FILE}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    if [ ! -d "$APP_DIR/.git" ]; then
        echo -e "${RED}未检测到安装目录或 Git 仓库，无法更新${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cd "$APP_DIR" || return
    git pull
    docker compose build
    docker compose up -d

    echo -e "${GREEN}✅ Emby-In-One 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    cd "$APP_DIR" || return
    docker compose restart
    echo -e "${GREEN}✅ Emby-In-One 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {
    cd "$APP_DIR" || return
    docker compose ps
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}未检测到安装目录，无需卸载${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cd "$APP_DIR" || return
    docker compose down 2>/dev/null
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Emby-In-One 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
