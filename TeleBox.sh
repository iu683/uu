#!/bin/bash
# ============================================
# TeleBox 一键管理脚本 (带配置向导 + 登录功能)
# 功能: 安装 / 启动 / 停止 / 卸载 / 日志查看 / 配置 / 登录
# ============================================

APP_NAME="telebox"
APP_DIR="$HOME/telebox"
GIT_REPO="https://github.com/TeleBoxDev/TeleBox.git"
ENV_FILE="$APP_DIR/.env"

GREEN="\033[32m"
RESET="\033[0m"

show_menu() {
    clear
    echo -e "${GREEN}=== TeleBox 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装 TeleBox${RESET}"
    echo -e "${GREEN}2) 启动 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}3) 停止 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}4) 重启 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}5) 查看运行日志${RESET}"
    echo -e "${GREEN}6) 配置 API 信息${RESET}"
    echo -e "${GREEN}7) 卸载 TeleBox${RESET}"
    echo -e "${GREEN}8) 登录 TeleBox（手机号验证）${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo
}

install_telebox() {
    echo -e "${GREEN}>>> 开始安装 TeleBox...${RESET}"
    sudo apt update
    sudo apt install -y curl git build-essential

    # 安装 Node.js 20.x
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs

    # 安装 PM2
    sudo npm install -g pm2

    # 克隆项目
    if [ ! -d "$APP_DIR" ]; then
        mkdir -p "$APP_DIR"
        git clone "$GIT_REPO" "$APP_DIR"
    else
        echo -e "${GREEN}>>> 目录已存在，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit
    npm install

    # 配置向导
    configure_telebox

    echo -e "${GREEN}>>> TeleBox 安装完成！${RESET}"
    echo -e "${GREEN}下一步: 请选择菜单 8 登录 TeleBox${RESET}"
}

start_telebox() {
    cd "$APP_DIR" || exit
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${GREEN}未检测到配置文件，先进行配置...${RESET}"
        configure_telebox
    fi
    pm2 start "npm start" --name "$APP_NAME"
    pm2 save
    sudo pm2 startup systemd -u $USER --hp $HOME
    echo -e "${GREEN}>>> TeleBox 已启动并设置开机自启${RESET}"
}

stop_telebox() {
    pm2 stop "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已停止${RESET}"
}

restart_telebox() {
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已重启${RESET}"
}

logs_telebox() {
    pm2 logs "$APP_NAME"
}

configure_telebox() {
    echo -e "${GREEN}>>> 配置 TeleBox API 信息${RESET}"
    read -rp "请输入 Telegram API_ID: " API_ID
    read -rp "请输入 Telegram API_HASH: " API_HASH

    cat > "$ENV_FILE" <<EOF
API_ID=$API_ID
API_HASH=$API_HASH
EOF

    echo -e "${GREEN}>>> 配置完成，已写入 $ENV_FILE${RESET}"
}

login_telebox() {
    echo -e "${GREEN}>>> 正在启动 TeleBox 登录流程...${RESET}"
    echo -e "${GREEN}请根据提示输入手机号、验证码、二步验证密码（如有）${RESET}"
    echo -e "${GREEN}登录成功后按 CTRL+C 停止，再通过菜单 2 启动 PM2 服务${RESET}"
    cd "$APP_DIR" || exit
    npm start
}

uninstall_telebox() {
    echo -e "${GREEN}>>> 卸载 TeleBox...${RESET}"
    pm2 delete "$APP_NAME"
    rm -rf "$APP_DIR"
    echo -e "${GREEN}>>> TeleBox 已卸载${RESET}"
}

while true; do
    show_menu
    read -rp "请选择操作: " choice
    case $choice in
        1) install_telebox ;;
        2) start_telebox ;;
        3) stop_telebox ;;
        4) restart_telebox ;;
        5) logs_telebox ;;
        6) configure_telebox ;;
        7) uninstall_telebox ;;
        8) login_telebox ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择，请重新输入${RESET}" ;;
    esac
    echo -e "${GREEN}按回车键继续...${RESET}"
    read
done
