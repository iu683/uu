#!/bin/bash

BASE_PORT=20000                  # 起始端口
DATA_DIR="$HOME/socks5_users"    # 存储账号目录
BIN_PATH="/usr/bin/microsocks"   # socks5 程序路径
mkdir -p "$DATA_DIR"

# 获取服务器 IP
SERVER_IP=$(curl -s ifconfig.me || echo "127.0.0.1")

install_socks5() {
    if [ ! -f "$BIN_PATH" ]; then
        echo "未检测到 microsocks，正在安装..."
        apt update && apt install -y microsocks
    fi
    echo "microsocks 已安装。"
}

start_socks5() {
    for file in "$DATA_DIR"/*.conf; do
        [ -e "$file" ] || continue
        source "$file"
        nohup $BIN_PATH -1 -i 0.0.0.0 -p "$PORT" -u "$USER" -P "$PASS" >/dev/null 2>&1 &
    done
    echo "所有 Socks5 已启动。"
}

stop_socks5() {
    pkill microsocks && echo "已停止所有 Socks5。"
}

gen_accounts() {
    read -p "请输入要生成的账号数量: " COUNT
    for i in $(seq 1 $COUNT); do
        USER="user$i"
        PASS=$(openssl rand -hex 4)
        PORT=$((BASE_PORT+i-1))
        CONF="$DATA_DIR/$USER.conf"
        echo "USER=$USER" > "$CONF"
        echo "PASS=$PASS" >> "$CONF"
        echo "PORT=$PORT" >> "$CONF"
        nohup $BIN_PATH -1 -i 0.0.0.0 -p "$PORT" -u "$USER" -P "$PASS" >/dev/null 2>&1 &
        echo "生成账号: socks://$USER:$PASS@$SERVER_IP:$PORT"
    done
}

list_accounts() {
    for file in "$DATA_DIR"/*.conf; do
        [ -e "$file" ] || { echo "没有账号。"; return; }
        source "$file"
        echo "socks://$USER:$PASS@$SERVER_IP:$PORT"
    done
}

delete_account() {
    list_accounts
    read -p "请输入要删除的用户名: " DEL_USER
    FILE="$DATA_DIR/$DEL_USER.conf"
    if [ -f "$FILE" ]; then
        source "$FILE"
        rm -f "$FILE"
        fuser -k "$PORT"/tcp >/dev/null 2>&1
        echo "已删除账号 $DEL_USER"
    else
        echo "未找到账号 $DEL_USER"
    fi
}

delete_all() {
    rm -f "$DATA_DIR"/*.conf
    pkill microsocks
    echo "已删除所有账号。"
}

status() {
    pgrep microsocks >/dev/null && echo "Socks5 正在运行。" || echo "Socks5 未运行。"
}

while true; do
    echo "    Socks5 管理工具     "
    echo "=============================="
    echo "1) 安装 socks5"
    echo "2) 启动 socks5"
    echo "3) 停止 socks5"
    echo "4) 批量生成账号"
    echo "5) 查看账号列表"
    echo "6) 删除指定账号"
    echo "7) 删除所有账号"
    echo "8) 状态"
    echo "9) 退出"
    read -p "请选择 (1-9): " choice
    case $choice in
        1) install_socks5 ;;
        2) start_socks5 ;;
        3) stop_socks5 ;;
        4) gen_accounts ;;
        5) list_accounts ;;
        6) delete_account ;;
        7) delete_all ;;
        8) status ;;
        9) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
