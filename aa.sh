#!/bin/bash
# ========================================
# reclip 一键管理脚本
# Debian 12 / Ubuntu 兼容
# Docker build + docker run 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="reclip"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/averygan/reclip.git"
IMAGE_NAME="reclip"
CONTAINER_NAME="reclip"
DEFAULT_PORT="8899"

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
    echo -e "${GREEN}=== reclip 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 查看状态${RESET}"
    echo -e "${GREEN}7) 卸载(含镜像和数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) app_status ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

check_requirements() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 git，正在安装...${RESET}"
        apt update
        apt install -y git
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update
        apt install -y curl
    fi

    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 ffmpeg，正在安装...${RESET}"
        apt update
        apt install -y ffmpeg
    fi

    if ! command -v pip3 >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 pip3，正在安装...${RESET}"
        apt update
        apt install -y python3-pip
    fi

    if ! command -v yt-dlp >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 yt-dlp，正在安装...${RESET}"
        pip3 install -U yt-dlp
    fi
}

install_app() {
    check_requirements

    read -p "请输入映射端口 [默认: ${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone "$REPO_URL" "$APP_DIR"
    else
        echo -e "${YELLOW}检测到项目目录已存在，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit 1

    echo -e "${GREEN}构建 Docker 镜像...${RESET}"
    docker build -t "$IMAGE_NAME" .

    echo -e "${GREEN}启动容器...${RESET}"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "127.0.0.1:${PORT}:8899" \
        --restart unless-stopped \
        "$IMAGE_NAME"

    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
访问地址: http://127.0.0.1:${PORT}
镜像名称: ${IMAGE_NAME}
容器名称: ${CONTAINER_NAME}
安装目录: ${APP_DIR}
EOF

    echo
    echo -e "${GREEN}✅ reclip 已安装并启动${RESET}"
    echo -e "${YELLOW}访问地址: http://127.0.0.1:${PORT}${RESET}"
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

    echo -e "${GREEN}拉取最新代码...${RESET}"
    git pull

    echo -e "${GREEN}重新构建镜像...${RESET}"
    docker build -t "$IMAGE_NAME" .

    local PORT
    PORT=$(docker inspect "$CONTAINER_NAME" --format '{{(index (index .HostConfig.PortBindings "8899/tcp") 0).HostPort}}' 2>/dev/null)

    if [[ -z "$PORT" ]]; then
        PORT="$DEFAULT_PORT"
    fi

    echo -e "${GREEN}重建并启动容器...${RESET}"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "127.0.0.1:${PORT}:8899" \
        --restart unless-stopped \
        "$IMAGE_NAME"

    echo -e "${GREEN}✅ reclip 已更新${RESET}"
    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到容器${RESET}"
        sleep 1
        menu
    fi

    docker logs -f "$CONTAINER_NAME"
    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到容器${RESET}"
        sleep 1
        menu
    fi

    docker restart "$CONTAINER_NAME" >/dev/null
    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

stop_app() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}未检测到容器${RESET}"
        sleep 1
        menu
    fi

    docker stop "$CONTAINER_NAME" >/dev/null
    echo -e "${GREEN}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

app_status() {
    echo -e "${GREEN}容器状态：${RESET}"
    docker ps -a --filter "name=${CONTAINER_NAME}"
    echo
    echo -e "${GREEN}镜像状态：${RESET}"
    docker images | grep "$IMAGE_NAME" || true
    echo
    echo -e "${GREEN}端口监听：${RESET}"
    ss -tulnp | grep -E ":${DEFAULT_PORT}|:8899" || true
    echo

    if [ -f "$APP_DIR/install-info.txt" ]; then
        echo -e "${GREEN}安装信息：${RESET}"
        cat "$APP_DIR/install-info.txt"
    fi

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ reclip 已卸载（包含镜像和数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
