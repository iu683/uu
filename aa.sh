#!/bin/bash
# ========================================
# MCSManager 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="mcsmanager"
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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== MCSManager 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/web/data" "$APP_DIR/web/logs" "$APP_DIR/daemon/data" "$APP_DIR/daemon/logs"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入 Web 访问端口 [默认:23333]: " input_web_port
    WEB_PORT=${input_web_port:-23333}
    check_port "$WEB_PORT" || return

    read -p "请输入 Daemon 端口 [默认:24444]: " input_daemon_port
    DAEMON_PORT=${input_daemon_port:-24444}
    check_port "$DAEMON_PORT" || return

    cat > "$COMPOSE_FILE" <<EOF
services:
  web:
    image: githubyumao/mcsmanager-web:latest
    container_name: mcsmanager-web
    ports:
      - "${WEB_PORT}:23333"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - $APP_DIR/web/data:/opt/mcsmanager/web/data
      - $APP_DIR/web/logs:/opt/mcsmanager/web/logs

  daemon:
    image: githubyumao/mcsmanager-daemon:latest
    container_name: mcsmanager-daemon
    restart: unless-stopped
    ports:
      - "${DAEMON_PORT}:24444"
    environment:
      - MCSM_DOCKER_WORKSPACE_PATH=$APP_DIR/daemon/data/InstanceData
    volumes:
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
      - $APP_DIR/daemon/data:/opt/mcsmanager/daemon/data
      - $APP_DIR/daemon/logs:/opt/mcsmanager/daemon/logs
      - /var/run/docker.sock:/var/run/docker.sock
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ MCSManager 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 访问地址: http://${SERVER_IP}:${WEB_PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ MCSManager 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart mcsmanager-web mcsmanager-daemon
    echo -e "${GREEN}✅ MCSManager 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}选择查看日志: 1) web 2) daemon${RESET}"
    read -p "请输入: " log_choice
    case $log_choice in
        1) docker logs -f mcsmanager-web ;;
        2) docker logs -f mcsmanager-daemon ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
}

check_status() {
    docker ps | grep mcsmanager
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ MCSManager 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
