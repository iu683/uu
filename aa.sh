#!/bin/bash
# ========================================
# Dockup 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="dockup"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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

        echo -e "${GREEN}=== Dockup 管理菜单 ===${RESET}"
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

    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " TG_CHAT_ID

    echo
    read -p "请输入检查间隔 [默认:12h]: " input_interval
    CHECK_INTERVAL=${input_interval:-12h}

    read -p "是否自动清理旧镜像? (true/false) [默认:true]: " input_cleanup
    CLEANUP=${input_cleanup:-true}

    read -p "首次启动发送测试消息? (true/false) [默认:true]: " input_test
    SETUP_TEST_MESSAGE=${input_test:-true}

    cat > "$ENV_FILE" <<EOF
TZ=Asia/Shanghai
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
CHECK_INTERVAL=${CHECK_INTERVAL}
CLEANUP=${CLEANUP}
SETUP_TEST_MESSAGE=${SETUP_TEST_MESSAGE}
EOF

    cat > "$COMPOSE_FILE" <<EOF
services:
  dockup:
    image: ghcr.io/shuijiao1/dockup:latest

    container_name: dockup

    restart: unless-stopped

    environment:
      TZ: \${TZ:-Asia/Shanghai}
      TG_BOT_TOKEN: \${TG_BOT_TOKEN}
      TG_CHAT_ID: \${TG_CHAT_ID}
      CHECK_INTERVAL: \${CHECK_INTERVAL:-12h}
      CLEANUP: \${CLEANUP:-true}
      SETUP_TEST_MESSAGE: \${SETUP_TEST_MESSAGE:-true}

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

    env_file:
      - .env

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    cd "$APP_DIR" || exit

    docker compose up -d

    echo
    echo -e "${GREEN}✅ Dockup 已启动${RESET}"
    echo -e "${YELLOW}📨 TG Chat ID: ${TG_CHAT_ID}${RESET}"
    echo -e "${YELLOW}⏱️ 检查间隔: ${CHECK_INTERVAL}${RESET}"
    echo -e "${YELLOW}🧹 自动清理: ${CLEANUP}${RESET}"
    echo -e "${YELLOW}📂 安装目录: $APP_DIR${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {

    cd "$APP_DIR" || return

    docker compose pull

    docker compose up -d

    echo -e "${GREEN}✅ 更新完成${RESET}"

    read -p "按回车返回菜单..."
}

restart_app() {

    docker restart dockup

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
}

view_logs() {

    docker logs -f dockup
}

check_status() {

    docker ps | grep dockup

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
