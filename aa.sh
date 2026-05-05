#!/bin/bash
# ========================================
# Remio Home 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="remio-home"
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
        echo -e "${GREEN}=== Remio Home 管理菜单 ===${RESET}"
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

    # 配置目录
    read -p "配置目录 [默认:$APP_DIR/config]: " input_config
    CONFIG_DIR=${input_config:-$APP_DIR/config}

    # 图标目录
    read -p "图标目录 [默认:$APP_DIR/icons]: " input_icons
    ICON_DIR=${input_icons:-$APP_DIR/icons}

    # 密码
    DEFAULT_PASS=$(openssl rand -base64 12 | tr -dc A-Za-z0-9 | head -c 12)
    read -p "访问密码 [默认随机生成]: " input_pass
    PASSWORD=${input_pass:-$DEFAULT_PASS}

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$ICON_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  remio-home:
    image: kasuie/remio-home
    container_name: remio-home
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      - TZ=Asia/Shanghai
      - PASSWORD=${PASSWORD}
    volumes:
      - ${CONFIG_DIR}:/remio-home/config
      - ${ICON_DIR}:/remio-home/public/icons
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    chmod -R 777 "$CONFIG_DIR"
    chmod -R 777 "$ICON_DIR"

    echo
    echo -e "${GREEN}✅ Remio Home 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🌐 配置地址: http://127.0.0.1:${PORT}/config${RESET}"
    echo -e "${YELLOW}🔑 登录密码: ${PASSWORD}${RESET}"
    echo -e "${YELLOW}📂 配置目录: ${CONFIG_DIR}${RESET}"
    echo -e "${YELLOW}🎨 图标目录: ${ICON_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Remio Home 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart remio-home
    echo -e "${GREEN}✅ Remio Home 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f remio-home
}

check_status() {
    docker ps | grep remio-home
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Remio Home 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu  
