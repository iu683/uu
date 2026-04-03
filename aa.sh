#!/bin/bash
# ========================================
# Audiobookshelf 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="audiobookshelf"
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
        echo -e "${GREEN}=== Audiobookshelf 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    # 端口
    read -p "请输入访问端口 [默认:13378]: " input_port
    PORT=${input_port:-13378}
    check_port "$PORT" || return

    # 有声书目录
    read -p "请输入有声书目录 [默认:$APP_DIR/audiobooks]: " input_books
    BOOKS_DIR=${input_books:-$APP_DIR/audiobooks}

    # 播客目录
    read -p "请输入播客目录 [默认:$APP_DIR/podcasts]: " input_pod
    POD_DIR=${input_pod:-$APP_DIR/podcasts}

    # 配置目录
    read -p "请输入配置目录 [默认:$APP_DIR/config]: " input_conf
    CONFIG_DIR=${input_conf:-$APP_DIR/config}

    # metadata目录
    read -p "请输入 metadata 目录 [默认:$APP_DIR/metadata]: " input_meta
    META_DIR=${input_meta:-$APP_DIR/metadata}

    mkdir -p "$BOOKS_DIR" "$POD_DIR" "$CONFIG_DIR" "$META_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  audiobookshelf:
    container_name: audiobookshelf
    image: ghcr.io/advplyr/audiobookshelf:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - ${BOOKS_DIR}:/audiobooks
      - ${POD_DIR}:/podcasts
      - ${CONFIG_DIR}:/config
      - ${META_DIR}:/metadata
    environment:
      TZ: Asia/Shanghai
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Audiobookshelf 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📚 有声书目录: ${BOOKS_DIR}${RESET}"
    echo -e "${GREEN}🎙 播客目录: ${POD_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Audiobookshelf 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart audiobookshelf
    echo -e "${GREEN}✅ Audiobookshelf 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f audiobookshelf
}

check_status() {
    docker ps | grep audiobookshelf
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Audiobookshelf 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
