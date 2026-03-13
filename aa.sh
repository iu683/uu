#!/bin/bash
# ========================================
# Music-DL 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="music-dl"
APP_DIR="/opt/$APP_NAME"
DATA_DIR="$APP_DIR/data"
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

get_ip() {
    curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Music-DL 管理菜单 ===${RESET}"
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

    mkdir -p "$DATA_DIR"
    chmod -R 777 "$DATA_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}

    check_port "$PORT" || return

    mkdir -p "$APP_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  music-dl:
    image: guohuiyuan/go-music-dl:latest
    container_name: music-dl
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8080"
    volumes:
      - ${DATA_DIR}:/home/appuser/data
    environment:
      - TZ=Asia/Shanghai
    command:
      [
        "./music-dl",
        "web",
        "--port","8080",
        "--no-browser",
        "--vg-cover",
        "--vg-audio",
        "--vg-lyric",
        "--vg-export"
      ]
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    IP=$(get_ip)

    echo
    echo -e "${GREEN}✅ Music-DL 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET}"
    echo -e "http://127.0.0.1:${PORT}"
    echo -e "${GREEN}📂 数据目录:${RESET} $DATA_DIR"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose pull
    docker compose down
    docker compose up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart music-dl
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f music-dl
}

check_status() {
    echo
    docker ps -a | grep music-dl
    echo
    docker stats music-dl --no-stream
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" 2>/dev/null || true

    docker compose down -v 2>/dev/null
    docker rm -f music-dl 2>/dev/null

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Music-DL 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

menu
