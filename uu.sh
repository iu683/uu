#!/bin/bash
# ========================================
# Codex Console 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="codex-console"
APP_DIR="/opt/$APP_NAME"
REPO="https://github.com/dou-jiang/codex-console.git"

COMPOSE_CMD=""

check_docker() {

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}未检测到 Docker Compose${RESET}"
        exit 1
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

check_git() {

    if ! command -v git &>/dev/null; then
        echo -e "${YELLOW}未检测到 Git，正在安装...${RESET}"
        apt update -y && apt install git -y
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

        echo -e "${GREEN}=== Codex Console 管理菜单 ===${RESET}"
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
    check_git

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否重新安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    echo -e "${GREEN}正在克隆项目...${RESET}"

    git clone "$REPO" "$APP_DIR"

    cd "$APP_DIR" || exit

    mkdir -p data logs

    echo
    read -p "请输入 WebUI 端口 [默认:1455]: " input_port
    PORT=${input_port:-1455}
    check_port "$PORT" || return

    read -p "请输入 noVNC 端口 [默认:6080]: " input_vnc
    NOVNC_PORT=${input_vnc:-6080}
    check_port "$NOVNC_PORT" || return

    read -p "请输入访问密码 [默认:admin123]: " input_pass
    PASSWORD=${input_pass:-admin123}

    sed -i "s/1455:1455/${PORT}:1455/g" docker-compose.yml
    sed -i "s/6080:6080/${NOVNC_PORT}:6080/g" docker-compose.yml
    sed -i "s/WEBUI_ACCESS_PASSWORD=.*/WEBUI_ACCESS_PASSWORD=${PASSWORD}/g" docker-compose.yml

    echo -e "${GREEN}构建镜像...${RESET}"

    $COMPOSE_CMD build

    echo -e "${GREEN}启动服务...${RESET}"

    $COMPOSE_CMD up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Codex Console 已启动${RESET}"
    echo -e "${GREEN}WebUI: http:/${SERVER_IP}:${PORT}${RESET}"
    echo -e "${GREEN}noVNC: http://${SERVER_IP}:${NOVNC_PORT}${RESET}"
    echo -e "${GREEN}密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}安装目录: ${APP_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    git pull

    $COMPOSE_CMD down
    $COMPOSE_CMD build
    $COMPOSE_CMD up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return

    $COMPOSE_CMD restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return

    $COMPOSE_CMD logs -f
}

check_status() {

    docker ps | grep webui

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return

    $COMPOSE_CMD down

    cd /

    rm -rf "$APP_DIR"

    echo -e "${RED}Codex Console 已卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
