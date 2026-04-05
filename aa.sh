#!/bin/bash
# ========================================
# TeleRelay 一键管理脚本
# Debian12 / Ubuntu 兼容 (自动 venv)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="TeleRelay"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="telerelay"
VENV_DIR="$APP_DIR/venv"

function menu() {
    clear
    echo -e "${GREEN}=== TeleRelay 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function install_app() {

    echo -e "${GREEN}正在安装依赖...${RESET}"

    apt update
    apt install -y python3 python3-pip python3-venv git

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone https://github.com/one-ea/TeleRelay.git "$APP_DIR"
    fi

    cd "$APP_DIR"

    echo -e "${GREEN}创建 Python 虚拟环境...${RESET}"
    python3 -m venv "$VENV_DIR"

    echo -e "${GREEN}安装依赖...${RESET}"
    $VENV_DIR/bin/pip install --upgrade pip
    $VENV_DIR/bin/pip install -r requirements.txt

    cp config.example.py config.py

    echo
    read -p "请输入 BOT TOKEN: " BOT_TOKEN
    read -p "请输入 OWNER ID: " OWNER_ID

    sed -i "s/BOT_TOKEN =.*/BOT_TOKEN = \"$BOT_TOKEN\"/" config.py
    sed -i "s/OWNER_ID =.*/OWNER_ID = $OWNER_ID/" config.py

    echo -e "${GREEN}创建 systemd 服务...${RESET}"

    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=TeleRelay Bot
After=network.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python bot.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME

    echo
    echo -e "${GREEN}✅ TeleRelay 已安装并启动${RESET}"
    echo -e "${GREEN}⚠️ 请先在 Telegram 给机器人发送 /start${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {

    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }

    echo -e "${GREEN}更新程序...${RESET}"

    git pull

    $VENV_DIR/bin/pip install -r requirements.txt

    systemctl restart $SERVICE_NAME

    echo -e "${GREEN}✅ TeleRelay 已更新并重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {

    systemctl stop $SERVICE_NAME
    systemctl disable $SERVICE_NAME

    rm -f /etc/systemd/system/$SERVICE_NAME.service

    rm -rf "$APP_DIR"

    systemctl daemon-reload

    echo -e "${GREEN}✅ TeleRelay 已卸载${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {

    journalctl -u $SERVICE_NAME -f

    read -p "按回车返回菜单..."
    menu
}

menu
