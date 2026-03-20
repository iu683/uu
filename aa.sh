#!/bin/bash
# ========================================
# qbitwebui 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="qbitwebui"
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
        echo -e "${GREEN}=== qbitwebui 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口
    read -p "请输入访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    # 数据目录
    read -p "请输入数据目录 [默认:$APP_DIR/data]: " input_data
    DATA_DIR=${input_data:-$APP_DIR/data}
    mkdir -p "$DATA_DIR"

    # 下载目录
    read -p "请输入下载目录（必须存在）: " DOWNLOAD_DIR
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        echo -e "${RED}❌ 下载目录不存在${RESET}"
        return
    fi

    # 加密密钥
    read -p "请输入 ENCRYPTION_KEY（留空自动生成）: " input_key
    ENCRYPTION_KEY=${input_key:-$(openssl rand -hex 32)}

    cat > "$COMPOSE_FILE" <<EOF
services:
  qbitwebui:
    image: ghcr.io/maciejonos/qbitwebui:latest
    container_name: qbitwebui
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    volumes:
      - ${DATA_DIR}:/data
      - ${DOWNLOAD_DIR}:/downloads:ro
    environment:
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      DOWNLOADS_PATH: /downloads
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ qbitwebui 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}🔐 ENCRYPTION_KEY: ${ENCRYPTION_KEY}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${DATA_DIR}${RESET}"
    echo -e "${GREEN}📥 下载目录: ${DOWNLOAD_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ qbitwebui 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart qbitwebui
    echo -e "${GREEN}✅ qbitwebui 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f qbitwebui
}

check_status() {
    docker ps | grep qbitwebui
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ qbitwebui 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
