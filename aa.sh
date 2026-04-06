#!/bin/bash
# ========================================
# HD-Icons 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="hd-icons"
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
        echo -e "${GREEN}=== HD-Icons 管理菜单 ===${RESET}"
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

    echo
    read -p "请输入访问端口 [默认:50560]: " input_port
    PORT=${input_port:-50560}
    check_port "$PORT" || return

    echo
    read -p "请输入图标存储目录 [默认:$APP_DIR/icons]: " input_icons
    ICON_DIR=${input_icons:-$APP_DIR/icons}
    mkdir -p "$ICON_DIR"

    echo
    read -p "请输入站点标题 [默认:图标库]: " input_title
    TITLE=${input_title:-图标库}

    cat > "$COMPOSE_FILE" <<EOF
services:
  hd-icons:
    image: xushier/hd-icons:latest
    container_name: hd-icons
    restart: always
    ports:
      - "127.0.0.1:${PORT}:50560"
    volumes:
      - ${ICON_DIR}:/app/icons
    environment:
      TITLE: ${TITLE}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ HD-Icons 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 图标目录: ${ICON_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ HD-Icons 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart hd-icons
    echo -e "${GREEN}✅ HD-Icons 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f hd-icons
}

check_status() {
    docker ps | grep hd-icons
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ HD-Icons 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
