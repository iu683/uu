#!/bin/bash
# ========================================
# TGBot RSS 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="TGBot_RSS"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== TGBot RSS 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 BotToken(机器人Token): " BotToken
    read -p "请输入 自己的ID (默认0): " ADMINIDS
    ADMINIDS=${ADMINIDS:-0}
    read -p "RSS 检查周期 [默认1分钟]: " Cycletime
    Cycletime=${Cycletime:-1}
    read -p "是否开启 Debug 模式 [true/false, 默认false]: " Debug
    Debug=${Debug:-false}
    read -p "代理 URL [默认空]: " ProxyURL
    read -p "额外推送接口 URL [默认空]: " Pushinfo

    mkdir -p "$APP_DIR"

    cat > "$COMPOSE_FILE" <<EOF

services:
  tgbot-rss:
    image: kwxos/tgbot-rss:latest
    container_name: TGBot_RSS
    restart: unless-stopped
    environment:
      - BotToken=$BotToken
      - ADMINIDS=$ADMINIDS
      - Cycletime=$Cycletime
      - Debug=$Debug
      - ProxyURL=$ProxyURL
      - Pushinfo=$Pushinfo
      - TZ=Asia/Shanghai
    volumes:
      - $APP_DIR:/root
EOF

    echo -e "BotToken=$BotToken\nADMINIDS=$ADMINIDS\nCycletime=$Cycletime\nDebug=$Debug\nProxyURL=$ProxyURL\nPushinfo=$Pushinfo" > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ TGBot RSS 已启动${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ TGBot RSS 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ TGBot RSS 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f TGBot_RSS
    read -p "按回车返回菜单..."
    menu
}

menu
