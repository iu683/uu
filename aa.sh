#!/bin/bash
# ========================================
# PhotoPrism 一键管理脚本
# Debian / Ubuntu 兼容
# Docker Compose 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="photoprism"
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
    echo -e "${GREEN}=== PhotoPrism 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新镜像${RESET}"
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

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit 1

    read -p "请输入访问端口 [默认: 2342]: " PORT
    read -p "请输入管理员密码 [默认: insecure]: " ADMIN_PASSWORD
    read -p "是否允许上传 NSFW 内容？[y/N]: " UPLOAD_NSFW
    read -p "请输入 storage 目录 [默认: /opt/photoprism/storage]: " STORAGE_DIR
    read -p "请输入 originals 照片目录 [默认: /opt/photoprism/Pictures]: " ORIGINALS_DIR

    PORT=${PORT:-2342}
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-insecure}
    STORAGE_DIR=${STORAGE_DIR:-/opt/photoprism/storage}
    ORIGINALS_DIR=${ORIGINALS_DIR:-/opt/photoprism/Pictures}

    if [[ "$UPLOAD_NSFW" == "y" || "$UPLOAD_NSFW" == "Y" ]]; then
        PHOTOPRISM_UPLOAD_NSFW="true"
    else
        PHOTOPRISM_UPLOAD_NSFW="false"
    fi

    mkdir -p "$STORAGE_DIR" "$ORIGINALS_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  photoprism:
    container_name: photoprism
    security_opt:
      - seccomp=unconfined
      - apparmor=unconfined
    ports:
      - "127.0.0.1:${PORT}:2342"
    environment:
      - PHOTOPRISM_UPLOAD_NSFW=${PHOTOPRISM_UPLOAD_NSFW}
      - PHOTOPRISM_ADMIN_PASSWORD=${ADMIN_PASSWORD}
    volumes:
      - ${STORAGE_DIR}:/photoprism/storage
      - ${ORIGINALS_DIR}:/photoprism/originals
    image: photoprism/photoprism:latest
EOF

    docker compose up -d

    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
访问地址: http://127.0.0.1:${PORT}
管理员账号: admin
管理员密码: ${ADMIN_PASSWORD}
Storage 目录: ${STORAGE_DIR}
Originals 目录: ${ORIGINALS_DIR}
EOF

    echo
    echo -e "${GREEN}✅ PhotoPrism 已安装并启动${RESET}"
    echo -e "${YELLOW}访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}管理员账号: admin${RESET}"
    echo -e "${YELLOW}管理员密码: ${ADMIN_PASSWORD}${RESET}"
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

    echo -e "${GREEN}✅ PhotoPrism 已更新${RESET}"
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
    ss -tulnp | grep -E ':2342' || true
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

    echo -e "${GREEN}✅ PhotoPrism 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
