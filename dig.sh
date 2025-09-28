#!/bin/bash
set -e

# ================== 配置 ==================
APP_NAME="TGBot_RSS"
IMAGE_NAME="kwxos/tgbot-rss:latest"
INSTALL_DIR="/opt/tgbot_rss"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_FILE="$INSTALL_DIR/tgbot_rss.conf"

# ================== 颜色 ==================
GREEN="\033[32m"
RESET="\033[0m"

# ================== 公共函数 ==================
check_env() {
    if ! command -v docker &> /dev/null; then
        echo -e "${GREEN}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" <<EOF
BotToken="$BotToken"
ADMINIDS="$ADMINIDS"
Cycletime="$Cycletime"
Debug="$Debug"
ProxyURL="$ProxyURL"
Pushinfo="$Pushinfo"
EOF
}

# ================== 安装/启动 ==================
install_app() {
    load_config

    read -p "请输入 Telegram Bot Token (默认: $BotToken): " input
    BotToken=${input:-$BotToken}

    read -p "请输入管理员 UID (默认: $ADMINIDS, 0 表示所有用户): " input
    ADMINIDS=${input:-$ADMINIDS}

    read -p "RSS 检查周期(分钟, 默认 ${Cycletime:-1}): " input
    Cycletime=${input:-${Cycletime:-1}}

    read -p "是否开启调试模式 (true/false, 默认 ${Debug:-false}): " input
    Debug=${input:-${Debug:-false}}

    read -p "代理服务器 URL (默认 ${ProxyURL:-空}): " input
    ProxyURL=${input:-$ProxyURL}

    read -p "推送接口 URL (默认 ${Pushinfo:-空}): " input
    Pushinfo=${input:-$Pushinfo}

    save_config
    mkdir -p "$DATA_DIR"

    echo -e "${GREEN}🚀 正在安装并启动 $APP_NAME ...${RESET}"

    docker run -d \
      --name $APP_NAME \
      -e BotToken="$BotToken" \
      -e ADMINIDS="$ADMINIDS" \
      -e Cycletime="$Cycletime" \
      -e Debug="$Debug" \
      -e ProxyURL="$ProxyURL" \
      -e Pushinfo="$Pushinfo" \
      -e TZ="Asia/Shanghai" \
      -v "$DATA_DIR:/root/" \
      $IMAGE_NAME

    echo -e "${GREEN}✅ $APP_NAME 已启动${RESET}"
}

# ================== 更新 ==================
update_app() {
    echo -e "${GREEN}🔄 正在更新 $APP_NAME ...${RESET}"
    docker pull $IMAGE_NAME
    docker stop $APP_NAME 2>/dev/null || true
    docker rm $APP_NAME 2>/dev/null || true
    install_app
    echo -e "${GREEN}✅ 容器已更新并启动${RESET}"
}

# ================== 卸载 ==================
uninstall_app() {
    read -p "⚠️ 确认卸载 $APP_NAME 并删除数据和配置吗? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker stop $APP_NAME 2>/dev/null || true
        docker rm $APP_NAME 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}✅ $APP_NAME 已卸载并清理数据${RESET}"
    else
        echo -e "${GREEN}❌ 已取消卸载${RESET}"
    fi
}

# ================== 查看日志 ==================
logs_app() {
    docker logs -f $APP_NAME
}

# ================== 菜单 ==================
menu() {
    clear
    echo -e "${GREEN}=== TGBot_RSS 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) logs_app ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择${RESET}" ;;
    esac
}

# ================== 主循环 ==================
check_env
while true; do
    menu
    read -p "按回车键返回菜单..." dummy
done
