#!/bin/bash
# ========================================
# Fingerprint Proxy Switchboard 管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="fingerprint-proxy-switchboard"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/6mb/fingerprint-proxy-switchboard.git"

generate_secret() {
    openssl rand -hex 16
}

check_docker() {

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker Compose v2${RESET}"
        exit 1
    fi
}

menu() {

    while true; do

        clear

        echo -e "${GREEN}=== Fingerprint Proxy Switchboard ===${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        rm -rf "$APP_DIR"
    fi

    echo

    read -p "面板端口 [默认6310]: " input_panel_port
    PANEL_PORT=${input_panel_port:-6310}

    read -p "Mihomo API端口 [默认6311]: " input_api_port
    MIHOMO_PORT=${input_api_port:-6311}

    read -p "请输入公网IP或域名: " PUBLIC_HOST

    PANEL_TOKEN=$(generate_secret)
    PROXY_PASS=$(generate_secret)
    MIHOMO_SECRET=$(generate_secret)

    cd /opt || exit

    git clone "$REPO_URL" "$APP_NAME"

    cd "$APP_DIR" || exit

    mkdir -p config

    cat > .env <<EOF
PANEL_HOST=127.0.0.1
PANEL_PORT=${PANEL_PORT}
PANEL_TOKEN=${PANEL_TOKEN}
PUBLIC_HOST=${PUBLIC_HOST}

PROXY_AUTH=fingerprint:${PROXY_PASS}

MIHOMO_API=http://127.0.0.1:${MIHOMO_PORT}
MIHOMO_SECRET=${MIHOMO_SECRET}
MIHOMO_CONTROLLER=127.0.0.1:${MIHOMO_PORT}
MIHOMO_CONFIG_PATH=/root/.config/mihomo/config.yaml

SLOT_PORTS=6181,6182,6183,6184,6185,6186

SOURCE_PATH=/app/config/source.yaml
SOURCES_PATH=/app/config/sources.yaml
OUTPUT_PATH=/app/config/config.yaml
DELAY_TEST_URL=https://www.gstatic.com/generate_204
EOF

    cat > config/source.yaml <<EOF
proxies:
  - name: Example-SS
    type: ss
    server: example.invalid
    port: 443
    cipher: aes-128-gcm
    password: change-me
EOF

    docker compose up -d --build

    echo
    echo -e "${GREEN}✅ Fingerprint Proxy Switchboard 已启动${RESET}"
    echo -e "${YELLOW}🌐 面板: http://127.0.0.1:${PANEL_PORT}${RESET}"
    echo -e "${YELLOW}🔑 PANEL_TOKEN: ${PANEL_TOKEN}${RESET}"
    echo -e "${YELLOW}🔐 PROXY_AUTH: fingerprint:${PROXY_PASS}${RESET}"
    echo -e "${YELLOW}📂 安装目录: ${APP_DIR}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    git pull
    docker compose up -d --build

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    cd "$APP_DIR" || return
    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    cd "$APP_DIR" || return
    docker compose logs -f
}

check_status() {

    cd "$APP_DIR" || return
    docker compose ps

    read -p "按回车返回菜单..."
}

uninstall_app() {

    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"

    echo -e "${RED}✅ 已彻底卸载${RESET}"

    read -p "按回车返回菜单..."
}

menu
