#!/bin/bash
# ========================================
# aMule 一键管理脚本
# Debian 12 / Ubuntu 兼容
# Docker Compose 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="amule"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

random_password() {
    openssl rand -hex 8
}

menu() {
    clear
    echo -e "${GREEN}=== aMule 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 编辑配置${RESET}"
    echo -e "${GREEN}7) 查看状态${RESET}"
    echo -e "${GREEN}8) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) edit_config ;;
        7) app_status ;;
        8) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

check_requirements() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 docker compose 插件，请检查 Docker 安装${RESET}"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        apt update
        apt install -y curl
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        apt update
        apt install -y openssl
    fi
}

install_app() {
    check_requirements

    mkdir -p "$APP_DIR/config" "$APP_DIR/incoming" "$APP_DIR/temp"
    cd "$APP_DIR" || exit 1

    local DEFAULT_UID DEFAULT_GID
    DEFAULT_UID=1000
    DEFAULT_GID=1000

    read -p "请输入 PUID [默认: ${DEFAULT_UID}]: " PUID
    read -p "请输入 PGID [默认: ${DEFAULT_GID}]: " PGID
    read -p "请输入时区 [默认: Asia/Shanghai]: " TZ
    read -p "请输入 GUI 密码 [留空自动生成]: " GUI_PWD
    read -p "请输入 WebUI 密码 [留空自动生成]: " WEBUI_PWD
    read -p "是否启用自动重启？[Y/n]: " AUTO_RESTART
    read -p "自动重启 cron [默认: 0 6 * * *]: " AUTO_RESTART_CRON
    read -p "是否启用自动分享？[y/N]: " AUTO_SHARE
    read -p "自动分享目录 [默认: /incoming;/my_movies]: " AUTO_SHARE_DIRS
    read -p "4711 WebUI 端口 [默认: 4711]: " PORT_WEB
    read -p "4712 远程控制端口 [默认: 4712]: " PORT_REMOTE
    read -p "4662 eD2k TCP 端口 [默认: 4662]: " PORT_ED2K_TCP
    read -p "4665 eD2k UDP 搜索端口 [默认: 4665]: " PORT_ED2K_UDP_SEARCH
    read -p "4672 eD2k UDP 端口 [默认: 4672]: " PORT_ED2K_UDP

    PUID=${PUID:-$DEFAULT_UID}
    PGID=${PGID:-$DEFAULT_GID}
    TZ=${TZ:-Asia/Shanghai}
    GUI_PWD=${GUI_PWD:-$(random_password)}
    WEBUI_PWD=${WEBUI_PWD:-$(random_password)}
    AUTO_RESTART_CRON=${AUTO_RESTART_CRON:-0 6 * * *}
    AUTO_SHARE_DIRS=${AUTO_SHARE_DIRS:-/incoming;/my_movies}
    PORT_WEB=${PORT_WEB:-4711}
    PORT_REMOTE=${PORT_REMOTE:-4712}
    PORT_ED2K_TCP=${PORT_ED2K_TCP:-4662}
    PORT_ED2K_UDP_SEARCH=${PORT_ED2K_UDP_SEARCH:-4665}
    PORT_ED2K_UDP=${PORT_ED2K_UDP:-4672}

    if [[ "$AUTO_RESTART" == "n" || "$AUTO_RESTART" == "N" ]]; then
        MOD_AUTO_RESTART_ENABLED="false"
    else
        MOD_AUTO_RESTART_ENABLED="true"
    fi

    if [[ "$AUTO_SHARE" == "y" || "$AUTO_SHARE" == "Y" ]]; then
        MOD_AUTO_SHARE_ENABLED="true"
    else
        MOD_AUTO_SHARE_ENABLED="false"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  amule:
    image: ngosang/amule
    container_name: amule
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - GUI_PWD=${GUI_PWD}
      - WEBUI_PWD=${WEBUI_PWD}
      - MOD_AUTO_RESTART_ENABLED=${MOD_AUTO_RESTART_ENABLED}
      - MOD_AUTO_RESTART_CRON=${AUTO_RESTART_CRON}
      - MOD_AUTO_SHARE_ENABLED=${MOD_AUTO_SHARE_ENABLED}
      - MOD_AUTO_SHARE_DIRECTORIES=${AUTO_SHARE_DIRS}
      - MOD_FIX_KAD_GRAPH_ENABLED=true
      - MOD_FIX_KAD_BOOTSTRAP_ENABLED=true
    ports:
      - "${PORT_WEB}:4711"
      - "${PORT_REMOTE}:4712"
      - "${PORT_ED2K_TCP}:4662"
      - "${PORT_ED2K_UDP_SEARCH}:4665/udp"
      - "${PORT_ED2K_UDP}:4672/udp"
    volumes:
      - ${APP_DIR}/config:/home/amule/.aMule
      - ${APP_DIR}/incoming:/incoming
      - ${APP_DIR}/temp:/temp
    restart: unless-stopped
EOF

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
访问地址: http://${SERVER_IP}:${PORT_WEB}
GUI 密码: ${GUI_PWD}
WebUI 密码: ${WEBUI_PWD}
配置目录: ${APP_DIR}/config
下载目录: ${APP_DIR}/incoming
临时目录: ${APP_DIR}/temp
EOF

    echo
    echo -e "${GREEN}✅ aMule 已安装并启动${RESET}"
    echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${PORT_WEB}${RESET}"
    echo -e "${YELLOW}GUI 密码: ${GUI_PWD}${RESET}"
    echo -e "${YELLOW}WebUI 密码: ${WEBUI_PWD}${RESET}"
    echo -e "${YELLOW}安装信息已保存到: ${APP_DIR}/install-info.txt${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        sleep 1
        menu
    }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ aMule 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose logs -f
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose restart
    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

stop_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose down
    echo -e "${GREEN}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

edit_config() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    nano "$COMPOSE_FILE"
    echo -e "${YELLOW}配置已编辑，正在重新部署...${RESET}"
    docker compose up -d

    echo -e "${GREEN}✅ 配置已生效${RESET}"
    read -p "按回车返回菜单..."
    menu
}

app_status() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    echo -e "${GREEN}容器状态：${RESET}"
    docker compose ps
    echo
    echo -e "${GREEN}端口监听：${RESET}"
    ss -tulnp | grep -E ':4711|:4712|:4662|:4665|:4672' || true
    echo
    if [ -f "$APP_DIR/install-info.txt" ]; then
        echo -e "${GREEN}安装信息：${RESET}"
        cat "$APP_DIR/install-info.txt"
    fi

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose down
    fi

    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ aMule 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
