#!/bin/bash
# ============================================
# TeleBox 一键管理脚本 (PM2 守护 + 自动登录 + 更新 + 清理)
# ============================================

APP_NAME="telebox"
APP_DIR="$HOME/telebox"
GIT_REPO="https://github.com/TeleBoxDev/TeleBox.git"
ENV_FILE="$APP_DIR/.env"
SESSION_DIR="$APP_DIR/sessions"

GREEN="\033[32m"
RESET="\033[0m"

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}=== TeleBox 管理菜单 ===${RESET}"
    echo -e "${GREEN}1)  安装 TeleBox${RESET}"
    echo -e "${GREEN}2)  启动 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}3)  停止 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}4)  重启 TeleBox (PM2)${RESET}"
    echo -e "${GREEN}5)  查看运行日志${RESET}"
    echo -e "${GREEN}6)  卸载 TeleBox${RESET}"
    echo -e "${GREEN}7)  登录 TeleBox（首次自动配置 + 后台 PM2 运行）${RESET}"
    echo -e "${GREEN}8)  一键更新 TeleBox${RESET}"
    echo -e "${GREEN}9)  PM2 状态查看${RESET}"
    echo -e "${GREEN}10) PM2 日志查看${RESET}"
    echo -e "${GREEN}11) PM2 重启 TeleBox${RESET}"
    echo -e "${GREEN}12) PM2 停止 TeleBox${RESET}"
    echo -e "${GREEN}13) PM2 删除 TeleBox 进程${RESET}"
    echo -e "${GREEN}14) PM2 无缝重载 TeleBox${RESET}"
    echo -e "${GREEN}15) PM2 实时监控面板${RESET}"
    echo -e "${GREEN}16) 安装 pm2-logrotate 日志管理插件${RESET}"
    echo -e "${GREEN}17) 清理过期日志和 session 文件${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo
}

# 安装 TeleBox
install_telebox() {
    echo -e "${GREEN}>>> 开始安装 TeleBox...${RESET}"
    sudo apt update
    sudo apt install -y curl git build-essential
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    sudo npm install -g pm2

    if [ ! -d "$APP_DIR" ]; then
        git clone "$GIT_REPO" "$APP_DIR"
    else
        echo -e "${GREEN}>>> 目录已存在，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit
    npm install

    echo -e "${GREEN}>>> TeleBox 安装完成！${RESET}"
    echo -e "${GREEN}下一步: 请选择菜单 7 登录 TeleBox 并自动后台运行${RESET}"
}

# 启动 TeleBox
start_telebox() {
    cd "$APP_DIR" || exit
    [ ! -f "$ENV_FILE" ] && echo -e "${GREEN}>>> 未检测到 API 配置，请先登录${RESET}" && return
    pm2 start "npm start" --name "$APP_NAME"
    pm2 save
    sudo pm2 startup systemd -u $USER --hp $HOME
    echo -e "${GREEN}>>> TeleBox 已启动并设置开机自启${RESET}"
}

# 停止 TeleBox
stop_telebox() {
    pm2 stop "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已停止${RESET}"
}

# 重启 TeleBox
restart_telebox() {
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已重启${RESET}"
}

# 无缝重载 TeleBox
reload_telebox() {
    pm2 reload "$APP_NAME"
    echo -e "${GREEN}>>> TeleBox 已无缝重载${RESET}"
}

# 查看运行日志
logs_telebox() {
    pm2 logs "$APP_NAME"
}

# 查看 PM2 状态
status_pm2() {
    pm2 status
}

# PM2 实时监控
monit_pm2() {
    pm2 monit
}

# 安装 pm2-logrotate
install_logrotate() {
    pm2 install pm2-logrotate
    echo -e "${GREEN}>>> pm2-logrotate 插件已安装${RESET}"
}

# 首次登录（自动配置 API + 后台运行）
login_telebox() {
    cd "$APP_DIR" || { echo -e "${GREEN}>>> 项目目录不存在！${RESET}"; return; }

    # 首次 API 配置
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${GREEN}>>> 未检测到 API 配置，正在配置${RESET}"
        read -rp "请输入 Telegram API_ID: " API_ID
        read -rp "请输入 Telegram API_HASH: " API_HASH
        cat > "$ENV_FILE" <<EOF
API_ID=$API_ID
API_HASH=$API_HASH
EOF
        echo -e "${GREEN}>>> API 配置完成${RESET}"
    fi

    # 首次登录验证
    echo -e "${GREEN}>>> 首次登录，请根据提示输入手机号和验证码完成登录${RESET}"
    npm start

    # 登录完成后自动后台运行
    echo -e "${GREEN}>>> 登录成功，正在切换到 PM2 后台运行...${RESET}"
    pm2 start "npm start" --name "$APP_NAME"
    pm2 save
    sudo pm2 startup systemd -u $USER --hp $HOME
    cleanup
    echo -e "${GREEN}>>> TeleBox 已在后台运行，并设置开机自启${RESET}"
}

# 更新 TeleBox
update_telebox() {
    echo -e "${GREEN}>>> 更新 TeleBox...${RESET}"
    [ ! -d "$APP_DIR" ] && { echo -e "${GREEN}请先安装 TeleBox${RESET}"; return; }
    cd "$APP_DIR" || exit
    git pull
    npm install
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}>>> 更新完成！TeleBox 已在后台运行${RESET}"
}

# 清理日志和 session
cleanup() {
    echo -e "${GREEN}>>> 开始清理过期日志和 session 文件...${RESET}"
    pm2 flush
    if [ -d "$SESSION_DIR" ]; then
        rm -f "$SESSION_DIR"/*.session
        echo -e "${GREEN}>>> TeleBox session 文件已清理${RESET}"
    fi
}

# 卸载 TeleBox
uninstall_telebox() {
    echo -e "${GREEN}>>> 卸载 TeleBox...${RESET}"
    pm2 delete "$APP_NAME"
    rm -rf "$APP_DIR"
    echo -e "${GREEN}>>> TeleBox 已卸载${RESET}"
}

# 主循环
while true; do
    show_menu
    read -rp "请选择操作: " choice
    case $choice in
        1) install_telebox ;;
        2) start_telebox ;;
        3) stop_telebox ;;
        4) restart_telebox ;;
        5) logs_telebox ;;
        6) uninstall_telebox ;;
        7) login_telebox ;;
        8) update_telebox ;;
        9) status_pm2 ;;
        10) logs_telebox ;;
        11) restart_telebox ;;
        12) stop_telebox ;;
        13) pm2 delete "$APP_NAME"; echo -e "${GREEN}>>> TeleBox 进程已删除${RESET}" ;;
        14) reload_telebox ;;
        15) monit_pm2 ;;
        16) install_logrotate ;;
        17) cleanup ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选择，请重新输入${RESET}" ;;
    esac
    echo -e "${GREEN}按回车键继续...${RESET}"
    read -r
done
