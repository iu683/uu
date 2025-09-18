#!/bin/bash
# ========================================
# tg_faka 一键管理脚本
# ========================================

APP_NAME="tg_faka"
TG_FAKA_URL="https://github.com/yuimoi/tg_faka/releases/download/release/tg_faka_linux.zip"
INSTALL_DIR="$HOME/tg_faka"
TG_FAKA_BIN="$INSTALL_DIR/tg_faka_linux"
LOG_FILE="$INSTALL_DIR/tg_faka.log"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

GREEN="\033[32m"
RESET="\033[0m"

# 安装函数
install_app() {
    echo -e "${GREEN}>>> 开始安装 $APP_NAME ...${RESET}"
    mkdir -p "$INSTALL_DIR"
    wget -q --show-progress "$TG_FAKA_URL" -O "$INSTALL_DIR/tg_faka_linux.zip"
    unzip -q -o "$INSTALL_DIR/tg_faka_linux.zip" -d "$INSTALL_DIR"
    chmod +x "$TG_FAKA_BIN"
    echo -e "${GREEN}>>> 安装完成！请确保 $INSTALL_DIR/.env/ 下存在配置文件${RESET}"
    echo -e "${GREEN}>>> 项目地址 https://github.com/yuimoi/tg_faka/tree/main/.env${RESET}"
}

# 启动函数
start_app() {
    if pgrep -f "$TG_FAKA_BIN" > /dev/null; then
        echo -e "${GREEN}>>> $APP_NAME 已经在运行${RESET}"
    else
        nohup "$TG_FAKA_BIN" > "$LOG_FILE" 2>&1 &
        echo -e "${GREEN}>>> $APP_NAME 已启动，日志文件: $LOG_FILE${RESET}"
    fi
}

# 停止函数
stop_app() {
    pkill -f "$TG_FAKA_BIN" && echo -e "${GREEN}>>> $APP_NAME 已停止${RESET}" || echo -e "${GREEN}>>> $APP_NAME 未运行${RESET}"
}

# 重启函数
restart_app() {
    stop_app
    sleep 2
    start_app
}

# 查看状态
status_app() {
    if pgrep -f "$TG_FAKA_BIN" > /dev/null; then
        echo -e "${GREEN}>>> $APP_NAME 正在运行${RESET}"
    else
        echo -e "${GREEN}>>> $APP_NAME 未运行${RESET}"
    fi
}

# 查看日志
show_log() {
    tail -f "$LOG_FILE"
}

# 卸载函数
uninstall_app() {
    stop_app
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo -e "${GREEN}>>> $APP_NAME 已卸载，文件目录和自启配置已删除${RESET}"
}

# 添加 systemd 服务
enable_autostart() {
    if [ ! -f "$SERVICE_FILE" ]; then
        sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=$APP_NAME Service
After=network.target

[Service]
Type=simple
ExecStart=$TG_FAKA_BIN
WorkingDirectory=$INSTALL_DIR
Restart=always
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable $APP_NAME
        sudo systemctl start $APP_NAME
        echo -e "${GREEN}>>> systemd 自启已启用，并已启动 $APP_NAME${RESET}"
    else
        echo -e "${GREEN}>>> systemd 自启已存在${RESET}"
    fi
}

# 取消 systemd 自启
disable_autostart() {
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl disable --now $APP_NAME
        sudo rm -f "$SERVICE_FILE"
        sudo systemctl daemon-reload
        echo -e "${GREEN}>>> systemd 自启已取消${RESET}"
    else
        echo -e "${GREEN}>>> 未检测到 systemd 自启配置${RESET}"
    fi
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN} $APP_NAME 一键管理脚本${RESET}"
    echo -e "${GREEN} 安装目录: $INSTALL_DIR${RESET}"
    echo -e "${GREEN}======================================${RESET}"
    echo -e "${GREEN}1. 安装 $APP_NAME${RESET}"
    echo -e "${GREEN}2. 启动 $APP_NAME${RESET}"
    echo -e "${GREEN}3. 停止 $APP_NAME${RESET}"
    echo -e "${GREEN}4. 重启 $APP_NAME${RESET}"
    echo -e "${GREEN}5. 查看状态${RESET}"
    echo -e "${GREEN}6. 查看日志${RESET}"
    echo -e "${GREEN}7. 卸载 $APP_NAME${RESET}"
    echo -e "${GREEN}8. 启用开机自启${RESET}"
    echo -e "${GREEN}9. 取消开机自启${RESET}"
    echo -e "${GREEN}0. 退出"
    echo -e "${GREEN}======================================${RESET}"
}

# 主逻辑
while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1) install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) restart_app ;;
        5) status_app ;;
        6) show_log ;;
        7) uninstall_app ;;
        8) enable_autostart ;;
        9) disable_autostart ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选项，请重新输入${RESET}" ;;
    esac
    echo ""
    read -p "按回车键继续..."
done
