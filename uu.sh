#!/bin/bash
# ========================================
# Heki 节点 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="heki"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# ==============================
# 检查 Docker
# ==============================

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

# ==============================
# 菜单
# ==============================

menu() {

    while true; do
        clear
        echo -e "${GREEN}=== Heki 节点管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"

        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) restart_app ;;
            3) update_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 安装
# ==============================

install_app() {

    check_docker

    mkdir -p "$APP_DIR"
    mkdir -p /opt/heki

    read -p "请输入 Panel 类型 [默认:sspanel-uim]: " PANEL_TYPE
    PANEL_TYPE=${PANEL_TYPE:-sspanel-uim}

    read -p "请输入Panel URL: " PANEL_URL
    read -p "请输入Panel Key: " PANEL_KEY

    cat > "$COMPOSE_FILE" <<EOF
services:
  heki:
    image: hekicore/heki:latest
    container_name: heki
    restart: on-failure
    network_mode: host
    environment:
      type: ${PANEL_TYPE}
      server_type: v2ray, vmess, vless, ss, ssr, trojan, hysteria, tuic, anytls, naive, mieru
      node_id: 1
      panel_url: ${PANEL_URL}
      panel_key: ${PANEL_KEY}
    volumes:
      - /opt/heki/:/etc/heki/
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Heki 已启动${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 重启
# ==============================

restart_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose restart

    echo -e "${GREEN}✅ Heki 已重启${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================

update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ Heki 已更新${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 查看日志
# ==============================

view_logs() {

    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"

    docker logs -f heki
}

# ==============================
# 查看状态
# ==============================

check_status() {

    docker ps | grep heki

    read -p "按回车返回菜单..."
}

# ==============================
# 卸载
# ==============================

uninstall_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose down

    rm -rf "$APP_DIR"

    echo -e "${RED}✅ Heki 已卸载${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 启动
# ==============================

menu
