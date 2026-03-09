#!/bin/bash

# anytls 安装/卸载管理脚本
# 功能：安装 anytls、修改端口或卸载

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
RED="\033[31m"

SERVICE_NAME="anytls"
BINARY_NAME="anytls-server"
BINARY_DIR="/usr/local/bin"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "必须使用 root 或 sudo 运行！"
    exit 1
fi

# 安装必要工具
function install_dependencies() {
    apt update -y >/dev/null 2>&1
    for dep in wget curl unzip openssl; do
        if ! command -v $dep &>/dev/null; then
            echo "正在安装 $dep..."
            apt install -y $dep || { echo "请手动安装 $dep"; exit 1; }
        fi
    done
}


# 自动检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)  BINARY_ARCH="amd64" ;;
    aarch64) BINARY_ARCH="arm64" ;;
    armv7l)  BINARY_ARCH="armv7" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/v0.0.12/anytls_0.0.12_linux_${BINARY_ARCH}.zip"
ZIP_FILE="/tmp/anytls_0.0.12_linux_${BINARY_ARCH}.zip"

# 获取公网 IP
get_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

# 操作完成后按回车返回菜单
pause_return() {
    read -p "按回车键返回菜单..." dummy
    show_menu
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}==== Anytls管理菜单 ====${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 卸载${RESET}"
    echo -e "${GREEN}3. 修改端口${RESET}"
    echo -e "${GREEN}4. 查看节点信息${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) install_anytls ;;
        2) uninstall_anytls ;;
        3) modify_port ;;
        4) show_node_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" && sleep 1 && show_menu ;;
    esac
}

# 安装 anytls
install_anytls() {

    install_dependencies

    DEFAULT_PORT=$((RANDOM%50000+10000))

    read -p "请输入监听端口 [默认随机:${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    echo "使用端口: $PORT"

    echo "[1/5] 下载 anytls..."
    wget "$DOWNLOAD_URL" -O "$ZIP_FILE" || { echo "下载失败！"; pause_return; return; }

    echo "[2/5] 解压文件..."
    unzip -o "$ZIP_FILE" -d "$BINARY_DIR" || { echo "解压失败！"; pause_return; return; }
    chmod +x "$BINARY_DIR/$BINARY_NAME"
    rm -f "$ZIP_FILE"

    read -s -p "设置密码（留空随机生成）: " PASSWORD
    echo
    [ -z "$PASSWORD" ] && PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)

    echo "[3/5] 配置 systemd 服务..."
    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=anytls Service
After=network.target

[Service]
ExecStart=$BINARY_DIR/$BINARY_NAME -l :$PORT -p $PASSWORD
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    echo "[4/5] 启动服务..."
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME

    SERVER_IP=$(get_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    echo -e "\n${GREEN}√ 安装完成！${RESET}"
    echo -e "${YELLOW}√ 端口: $PORT${RESET}"
    echo -e "${YELLOW}√ 密码: $PASSWORD${RESET}"
    echo -e "${GREEN}V2rayN:${GREEN}"
    echo -e "${YELLOW}anytls://$PASSWORD@$SERVER_IP:$PORT/?insecure=1#$HOSTNAME${GREEN}"
    echo -e "${GREEN}Surge :${GREEN}"
    echo -e "${YELLOW}$HOSTNAME = anytls, $SERVER_IP, $PORT, password=$PASSWORD, tfo=true, skip-cert-verify=true, reuse=false${GREEN}"

    pause_return
}

# 卸载
uninstall_anytls() {
    echo "正在卸载 anytls..."
    systemctl stop $SERVICE_NAME 2>/dev/null
    systemctl disable $SERVICE_NAME 2>/dev/null
    [ -f "$BINARY_DIR/$BINARY_NAME" ] && rm -f "$BINARY_DIR/$BINARY_NAME"
    [ -f "/etc/systemd/system/$SERVICE_NAME.service" ] && rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    NODE_FILE="/etc/anytls/node.txt"
    [ -f "$NODE_FILE" ] && rm -f "$NODE_FILE"
    systemctl daemon-reload
    echo -e "${GREEN}anytls 已完全卸载！${RESET}"

    pause_return
}

# 显示节点信息
show_node_info() {
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    BINARY_FILE="$BINARY_DIR/$BINARY_NAME"

    if [ ! -f "$SERVICE_FILE" ] || [ ! -f "$BINARY_FILE" ]; then
        echo -e "${YELLOW}未检测到 anytls 服务或二进制文件${RESET}"
        pause_return
        return
    fi

    # 从 systemd 文件中提取端口和密码
    PORT=$(grep -oP ':\K[0-9]+' "$SERVICE_FILE" | head -1)
    PASSWORD=$(grep -oP '\-p \K\S+' "$SERVICE_FILE")
    SERVER_IP=$(get_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    echo -e "${GREEN}==== 当前 anytls 节点信息 ====${RESET}"
    echo -e "${YELLOW}端口: $PORT${RESET}"
    echo -e "${YELLOW}密码: $PASSWORD${RESET}"
    echo -e "${YELLOW}服务器 IP: $SERVER_IP${RESET}"
    echo -e "${YELLOW}V6VPS替换IP地址为V6${RESET}"
    echo -e "${GREEN}V2rayN:${GREEN}"
    echo -e "${YELLOW}anytls://$PASSWORD@$SERVER_IP:$PORT/?insecure=1#$HOSTNAME${GREEN}"
    echo -e "${GREEN}Surge:${GREEN}"
    echo -e "${YELLOW}$HOSTNAME = anytls, $SERVER_IP, $PORT, password=$PASSWORD, tfo=true, skip-cert-verify=true, reuse=false${GREEN}"

    pause_return
}


# 修改端口
modify_port() {
    if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        echo -e "${YELLOW}未检测到已安装的 anytls 服务${RESET}"
        pause_return
        return
    fi
    read -p "请输入新端口: " NEW_PORT
    [ -z "$NEW_PORT" ] && echo "端口不能为空" && pause_return && return
    sed -i -r "s/-l 0\.0\.0\.0:[0-9]+/-l 0.0.0.0:$NEW_PORT/" /etc/systemd/system/$SERVICE_NAME.service
    systemctl daemon-reload
    systemctl restart $SERVICE_NAME
    echo -e "${GREEN}端口已修改为 $NEW_PORT 并重启服务${RESET}"

    pause_return
}

# 启动菜单
show_menu
