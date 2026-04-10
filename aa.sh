#!/bin/bash
# ========================================
# Let-Bot 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="let-bot"
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
        echo -e "${GREEN}=== Let-Bot 管理菜单 ===${RESET}"
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
    read -p "请输入 SiliconFlow API Key: " API_KEY

    echo
    read -p "请输入 Telegram Bot Token: " BOT_TOKEN

    echo
    read -p "请输入 Telegram Chat ID: " CHAT_ID

    echo
    read -p "请输入数据目录 [默认:$APP_DIR/data]: " input_data
    DATA_DIR=${input_data:-$APP_DIR/data}

    mkdir -p "$DATA_DIR"

cat > "$COMPOSE_FILE" <<EOF
services:
  let_bot:
    image: tyer199/let_bot:v3.5
    container_name: let_bot
    restart: unless-stopped
    environment:
      - SILICON_API_KEY=${API_KEY}
      - TG_BOT_TOKEN=${BOT_TOKEN}
      - TG_CHAT_ID=${CHAT_ID}
      - TZ=Asia/Shanghai
    volumes:
      - ${DATA_DIR}:/app/data
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置${RESET}"
        return
    fi

    echo
    echo -e "${GREEN}✅ Let-Bot 已启动${RESET}"
    echo -e "${GREEN}📂 数据目录: ${DATA_DIR}${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Let-Bot 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart let_bot
    echo -e "${GREEN}✅ Let-Bot 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f let_bot
}

check_status() {
    docker ps | grep let_bot
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Let-Bot 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
