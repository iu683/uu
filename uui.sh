#!/bin/bash
# ============================================
# TeleBox 一键管理脚本 (自动登录 + PM2 守护 + 更新 + 完整管理 + 清理)
# ============================================

APP_NAME="telebox"
APP_DIR="$HOME/telebox"
GIT_REPO="https://github.com/TeleBoxDev/TeleBox.git"
ENV_FILE="$APP_DIR/.env"
SESSION_DIR="$APP_DIR/sessions"  # 假设 TeleBox session 文件都在这里

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
    echo -e "${GREEN}8) 登录 TeleBox（手机号验证 + 自动后台运行）${RESET}"
    echo -e "${GREEN}9) 一键更新 TeleBox${RESET}"
    echo -e "${GREEN}10) PM2 状态查看${RESET}"
    echo -e "${GREEN}11) PM2 日志查看${RESET}"
    echo -e "${GREEN}12) PM2 重启 TeleBox${RESET}"
    echo -e "${GREEN}13) PM2 停止 TeleBox${RESET}"
    echo -e "${GREEN}14) PM2 删除 TeleBox 进程${RESET}"
    echo -e "${GREEN}15) PM2 无缝重载 TeleBox${RESET}"
    echo -e "${GREEN}16) PM2 实时监控面板${RESET}"
    echo -e "${GREEN}17) 安装 pm2-logrotate 日志管理插件${RESET}"
    echo -e "${GREEN}18) 清理过期日志和 session 文件${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo
}

install_telebox() {
    echo -e "${GREEN}>>> 开始安装 TeleBox...${RESET}"
    sudo apt update
    sudo apt install -y curl git build-essential

    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    sudo npm install -g pm2

    if [ ! -d "$APP_DIR" ]; then
        mkdir -p "$APP_DIR"
        git clone "$GIT_REPO" "$APP_DIR"
    else
        echo -e "${GREEN}>>> 目录已存在，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit
    npm install
    configure_telebox

    echo -e "${GREEN}>>> TeleBox 安装完成！${RESET}"
    echo -e "${GREEN}下一步: 请选择菜单 8 登录 TeleBox 并自动启动后台${RESET}"
}

start_telebox() {
    cd "$APP_DIR" || exit
    [ ! -f "$ENV_FILE" ] && configure_telebox
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

reload_telebox() {
    pm2 reload "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已无缝重载${RESET}"
}

logs_telebox() {
    pm2 logs "$APP_NAME"
}

status_pm2() {
    pm2 status
}

monit_pm2() {
    pm2 monit
}

install_logrotate() {
    pm2 install pm2-logrotate
    echo -e "${GREEN}>>> pm2-logrotate 插件已安装${RESET}"
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
    echo -e "${GREEN}>>> 启动 TeleBox 登录流程...${RESET}"
    cd "$APP_DIR" || exit
    npm start
    echo -e "${GREEN}>>> 登录完成，正在自动启动后台 PM2 服务...${RESET}"
    pm2 start "npm start" --name "$APP_NAME"
    pm2 save
    sudo pm2 startup systemd -u $USER --hp $HOME
    echo -e "${GREEN}>>> TeleBox 已在后台运行并设置开机自启${RESET}"
}

update_telebox() {
    echo -e "${GREEN}>>> 更新 TeleBox...${RESET}"
    [ ! -d "$APP_DIR" ] && { echo -e "${GREEN}请先安装 TeleBox${RESET}"; return; }
    cd "$APP_DIR" || exit
    git pull
    npm install
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}>>> 更新完成！TeleBox 已在后台运行${RESET}"
}

cleanup() {
    echo -e "${GREEN}>>> 开始清理过期日志和 session 文件...${RESET}"
    # 清理 pm2 日志
    pm2 flush
    echo -e "${GREEN}>>> PM2 日志已清空${RESET}"
    # 清理 session 文件
    if [ -d "$SESSION_DIR" ]; then
        rm -f "$SESSION_DIR"/*.session
        echo -e "${GREEN}>>> TeleBox session 文件已清理${RESET}"
    else
        echo -e "${GREEN}>>> session 目录不存在，跳过${RESET}"
    fi
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
        9) update_telebox ;;
        10) status_pm2 ;;
        11) logs_telebox ;;
        12) restart_telebox ;;
        13) stop_telebox ;;
        14) pm2 delete "$APP_NAME"; echo -e "${GREEN}>>> TeleBox 进程已删除${RESET}" ;;
        15) reload_telebox ;;
        16) monit_pm2 ;;
        17) install_logrotate ;;
        18) cleanup ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择，请重新输入${RESET}" ;;
    esac
    echo -e "${GREEN}按回车键继续...${RESET}"
    read
done
