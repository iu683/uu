#!/bin/bash
# ======================================
# Syncthing 一键管理脚本
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="syncthing"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== Syncthing 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    mkdir -p "$APP_DIR/config" "$APP_DIR/Documents" "$APP_DIR/Media"

    # 设置目录权限
    chown -R 1000:1000 "$APP_DIR"
    chmod -R 755 "$APP_DIR"

    read -rp "请输入 Web 管理端口 [默认:8384]: " web_port
    web_port=${web_port:-8384}

    cat > "$COMPOSE_FILE" <<EOF
services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    container_name: syncthing
    hostname: syncthing
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
    volumes:
      - $APP_DIR/config:/config
      - $APP_DIR/Documents:/Documents
      - $APP_DIR/Media:/Media
    ports:
      - "127.0.0.1:${web_port}:8384"
      - "22000:22000/tcp"
      - "22000:22000/udp"
      - "21027:21027/udp"
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ Syncthing 已启动${RESET}"
    echo -e "${YELLOW}Web 管理地址: http://127.0.0.1:${web_port}${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Syncthing 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }

    echo -e "${RED}是否同时删除数据目录？ (y/N)${RESET}"
    read -rp "选择: " confirm
    docker compose down -v

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$APP_DIR"
        echo -e "${RED}✅ Syncthing 已卸载，数据已删除${RESET}"
    else
        echo -e "${YELLOW}✅ Syncthing 已卸载，数据目录保留在 $APP_DIR${RESET}"
    fi

    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f syncthing
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
