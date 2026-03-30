#!/bin/bash
# ========================================
# Meridian 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="meridian"
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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Meridian 管理菜单 ===${RESET}"
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

    # 主端口
    read -p "请输入主访问端口 [默认:9090]: " input_port
    PORT=${input_port:-9090}

    # 辅助端口范围
    read -p "请输入辅助端口范围 [默认:8001-8010]: " input_range
    PORT_RANGE=${input_range:-8001-8010}

    # 数据卷
    read -p "请输入数据卷名称 [默认:meridian-data]: " input_volume
    VOLUME_NAME=${input_volume:-meridian-data}

    # JWT 密钥
    read -p "请输入 JWT 密钥 (留空自动生成): " input_jwt
    JWT_SECRET=${input_jwt:-$(openssl rand -hex 32)}

    cat > "$COMPOSE_FILE" <<EOF
services:
  meridian:
    container_name: meridian
    image: ghcr.io/snnabb/meridian:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:9090"
      - "${PORT_RANGE}:${PORT_RANGE}"
    volumes:
      - ${VOLUME_NAME}:/app/data
    environment:
      - JWT_SECRET=${JWT_SECRET}

volumes:
  ${VOLUME_NAME}:
    external: true
    name: ${VOLUME_NAME}
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Meridian 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据卷: ${VOLUME_NAME}${RESET}"
    echo -e "${GREEN}🔑 JWT_SECRET: ${JWT_SECRET}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Meridian 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart meridian
    echo -e "${GREEN}✅ Meridian 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f meridian
}

check_status() {
    docker ps | grep meridian
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Meridian 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
