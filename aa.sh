#!/bin/bash
# ========================================
# emby-pulse 一键管理脚本
# Debian / Ubuntu / 群晖 Docker 环境兼容
# Docker Compose 部署（端口映射模式）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="emby-pulsepro"
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

menu() {
    clear
    echo -e "${GREEN}=== emby-pulse pro 管理菜单 ===${RESET}"
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
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update
        apt install -y curl
    fi
}

install_app() {
    check_requirements

    mkdir -p "$APP_DIR/config" "$APP_DIR/data"
    cd "$APP_DIR" || exit 1

    echo -e "${GREEN}请填写 emby-pulse 配置${RESET}"

    read -p "请输入时区 [默认: Asia/Shanghai]: " TZ
    read -p "请输入 Emby 地址(如 http://192.168.31.2:8096): " EMBY_HOST
    read -p "请输入 Emby API Key: " EMBY_API_KEY
    read -p "请输入 Playback Reporting 数据库宿主机目录 [默认: /opt/emby/data]: " EMBY_DB_DIR
    read -p "请输入数据库文件容器路径 [默认: /emby-data/playback_reporting.db]: " DB_PATH
    read -p "请输入后台端口 [默认: 10307]: " PORT_ADMIN
    read -p "请输入用户中心端口 [默认: 10308]: " PORT_USER

    TZ=${TZ:-Asia/Shanghai}
    EMBY_DB_DIR=${EMBY_DB_DIR:-/opt/emby/data}
    DB_PATH=${DB_PATH:-/emby-data/playback_reporting.db}
    PORT_ADMIN=${PORT_ADMIN:-10307}
    PORT_USER=${PORT_USER:-10308}

    mkdir -p "$EMBY_DB_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  emby-pulse:
    image: zeyu8023/embypulse-pro:latest
    container_name: emby-pulse
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_ADMIN}:10307"
      - "127.0.0.1:${PORT_USER}:10308"
    volumes:
      - ${EMBY_DB_DIR}:/emby-data
      - ${APP_DIR}/config:/workspace/config
      - ${APP_DIR}/data:/workspace/data
    environment:
      TZ: ${TZ}
      DB_PATH: ${DB_PATH}
      EMBY_HOST: ${EMBY_HOST}
      EMBY_API_KEY: ${EMBY_API_KEY}
EOF

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
后台地址: http://127.0.0.1:${PORT_ADMIN}
用户中心: http://127.0.0.1:${PORT_USER}
Emby 地址: ${EMBY_HOST}
数据库目录: ${EMBY_DB_DIR}
配置目录: ${APP_DIR}/config
数据目录: ${APP_DIR}/data
EOF

    echo
    echo -e "${GREEN}✅ emby-pulse 已安装并启动${RESET}"
    echo -e "${YELLOW}后台地址: http://127.0.0.1:${PORT_ADMIN}${RESET}"
    echo -e "${YELLOW}用户中心: http://127.0.0.1:${PORT_USER}${RESET}"
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

    echo -e "${GREEN}✅ emby-pulse 已更新${RESET}"
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
    ss -tulnp | grep -E ':10307|:10308' || true
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

    echo -e "${GREEN}✅ emby-pulse 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
