#!/bin/bash
# ========================================
# WebDAV 一键管理脚本（支持自定义目录）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="webdav"
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
        echo -e "${GREEN}=== WebDAV 管理菜单 ===${RESET}"
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

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    check_port "$PORT" || return

    read -p "请输入用户名 [默认:webdav]: " input_user
    USERNAME=${input_user:-webdav}

    read -p "请输入密码 [默认:webdav]: " input_pass
    PASSWORD=${input_pass:-webdav}

    read -p "请输入存储目录 [默认:/opt/webdav/data]: " input_path
    DATA_DIR=${input_path:-/opt/webdav/data}
    
    mkdir -p "$APP_DIR"
    mkdir -p "$DATA_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  webdav:
    image: apachewebdav/apachewebdav:latest
    container_name: webdav
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:80"
    environment:
      AUTH_TYPE: Digest
      USERNAME: ${USERNAME}
      PASSWORD: ${PASSWORD}
      PUID: 1000
      PGID: 1001
    volumes:
      - ${DATA_DIR}:/var/lib/dav/data
EOF

    cd "$APP_DIR" || mkdir -p "$APP_DIR" && cd "$APP_DIR"

    docker compose up -d

    echo
    echo -e "${GREEN}✅ WebDAV 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}👤 用户名: ${USERNAME}${RESET}"
    echo -e "${GREEN}🔑 密码: ${PASSWORD}${RESET}"
    echo -e "${GREEN}📂 存储目录: ${DATA_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ WebDAV 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart webdav
    echo -e "${GREEN}✅ WebDAV 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f webdav
}

check_status() {
    docker ps | grep webdav
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}⚠ WebDAV 已卸载（不会删除自定义数据目录）${RESET}"
    read -p "按回车返回菜单..."
}

menu
