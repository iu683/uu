#!/bin/bash
# ======================================
# WireGuard 一键管理脚本 (LinuxServer Docker)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="wireguard"
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
    echo -e "${GREEN}=== WireGuard 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR/config"
    chown -R 1000:1000 "$APP_DIR"
    chmod -R 755 "$APP_DIR"

    read -rp "请输入服务器公网 IP 或域名: " SERVERURL
    read -rp "请输入 WireGuard 端口 [默认:51820]: " SERVERPORT
    SERVERPORT=${SERVERPORT:-51820}
    read -rp "要创建的客户端数量 [默认:1]: " PEERS
    PEERS=${PEERS:-1}
    read -rp "内部子网 [默认:10.13.13.0]: " NETWORK
    NETWORK=${NETWORK:-10.13.13.0}

    cat > "$COMPOSE_FILE" <<EOF

services:
  wireguard:
    container_name: wireguard
    image: lscr.io/linuxserver/wireguard:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - SERVERURL=${SERVERURL}
      - SERVERPORT=${SERVERPORT}
      - PEERS=${PEERS}
      - INTERNAL_SUBNET=${NETWORK}
      - ALLOWEDIPS=${NETWORK}/24
      - PERSISTENTKEEPALIVE_PEERS=all
      - LOG_CONFS=true
    volumes:
      - $APP_DIR/config:/config
      - /lib/modules:/lib/modules
    restart: always
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo -e "${GREEN}✅ WireGuard 已启动${RESET}"
    echo -e "${YELLOW}服务器地址: $SERVERURL:$SERVERPORT${RESET}"
    echo -e "${GREEN}客户端数量: $PEERS${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"

    # 安装完成默认显示二维码和完整配置
    echo -e "${YELLOW}所有客户端二维码配置: ${GREEN}"
    docker exec -it wireguard bash -c '
        for i in $(ls /config | grep peer_ | sed "s/peer_//"); do
            echo "--- $i ---"
            /app/show-peer $i
        done
    '

    sleep 2
    echo
    echo -e "${YELLOW}所有客户端完整配置: ${GREEN}"
    docker exec wireguard sh -c 'for d in /config/peer_*; do echo "# $(basename $d) "; cat $d/*.conf; echo; done'

    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ WireGuard 已更新并重启完成${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ WireGuard 已卸载，数据已删除${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    docker logs -f wireguard
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
