#!/bin/bash
# ========================================
# Emby 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"
APP_NAME="emby"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Emby   管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {

    # 🔍 核心逻辑：自动检测系统架构
    local arch=$(uname -m)
    local emby_image=""

    if [[ "$arch" == "x86_64" ]]; then
        emby_image="emby/embyserver:latest"
        arch_title="AMD64 (x86_64)"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        emby_image="emby/embyserver_arm64v8:latest"
        arch_title="ARM64 (aarch64)"
    else
        echo -e "${RED}❌ 未知或不支持的系统架构: $arch${RESET}"
        read -p "按回车返回菜单..."
        menu
        return
    fi

    echo -e "${GREEN}检测到系统架构为: ${YELLOW}$arch_title${RESET}"


    read -p "请输入 HTTP 端口 [默认:8096]: " input_port
    PORT=${input_port:-8096}

    read -p "请输入 HTTPS 端口 [默认:8920]: " input_https
    HTTPS_PORT=${input_https:-8920}

    read -p "请输入宿主机媒体目录 [默认:/opt/emby/media]: " input_media
    MEDIA_DIR=${input_media:-/opt/emby/media}

    echo -e "是否启用硬件转码? (y/n) 默认 n"
    read -p "选择: " enable_hw
    ENABLE_HW=${enable_hw:-n}

    mkdir -p "$APP_DIR"

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  emby:
    image: ${emby_image}
    container_name: emby
    restart: unless-stopped
    ports:
      - "127.0.0.1:$PORT:8096"
      - "127.0.0.1:$HTTPS_PORT:8920"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./config:/config
      - $MEDIA_DIR:/mnt/share1
EOF

    if [[ "$ENABLE_HW" =~ [yY] ]]; then
        cat >> "$COMPOSE_FILE" <<EOF
    devices:
      - /dev/dri:/dev/dri
EOF
    fi

    # 保存配置
    {
        echo "PORT=$PORT"
        echo "HTTPS_PORT=$HTTPS_PORT"
        echo "MEDIA_DIR=$MEDIA_DIR"
        echo "ENABLE_HW=$ENABLE_HW"
    } > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Emby 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}📂 容器目录: /mnt/share1${RESET}"
    echo -e "${GREEN}🎬 媒体目录: $MEDIA_DIR${RESET}"
    [[ "$ENABLE_HW" =~ [yY] ]] && echo -e "${GREEN}⚡ 已启用硬件转码支持${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Emby 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Emby 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Emby 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f emby
    read -p "按回车返回菜单..."
    menu
}

menu
