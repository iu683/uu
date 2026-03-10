#!/bin/bash
# ========================================
# IYUUPlus 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="iyuuplus"
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

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== IYUUPlus 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载（含数据）${RESET}"
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

    read -p "请输入访问端口 [默认:8780]: " input_port
    PORT=${input_port:-8780}

    check_port "$PORT" || return

    mkdir -p /opt/iyuuplus/iyuu
    mkdir -p /opt/iyuuplus/data

    cat > "$COMPOSE_FILE" <<EOF
services:
  iyuuplus-dev:
    image: iyuucn/iyuuplus-dev:latest
    container_name: IYUUPlus
    restart: always
    stdin_open: true
    tty: true
    volumes:
      - /opt/iyuuplus/iyuu:/iyuu
      - /opt/iyuuplus/data:/data
    ports:
      - "127.0.0.1:${PORT}:8780"
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ IYUUPlus 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}📂 数据目录: /root/iyuu${RESET}"
    echo -e "${YELLOW}📂 数据目录: /root/data${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 重启
# ==============================

restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose restart

    echo -e "${GREEN}✅ IYUUPlus 已重启${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================

update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ IYUUPlus 已更新${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 查看日志
# ==============================

view_logs() {

    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"

    docker logs -f IYUUPlus
}

# ==============================
# 查看状态
# ==============================

check_status() {

    docker ps | grep IYUUPlus

    read -p "按回车返回菜单..."
}

# ==============================
# 卸载
# ==============================

uninstall_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }

    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ IYUUPlus 已卸载${RESET}"

    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================

menu
