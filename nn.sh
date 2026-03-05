#!/bin/bash
# ========================================
# qBittorrent-Nox 一键管理脚本 (统一 /opt 文件夹)
# ========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

SERVICE_NAME="qbittorrent"
APP_DIR="/opt/qbittorrent"
CONFIG_DIR="$APP_DIR/config"
DOWNLOAD_DIR="$APP_DIR/downloads"

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。"
}

# 检查并创建目录
mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
chown -R $(whoami):$(whoami) "$APP_DIR"
chmod -R 755 "$APP_DIR"

# 部署 qBittorrent-Nox
install_qbittorrent() {

    echo -ne "请输入 WebUI 端口 (默认8080): "
    read WEBUI_PORT
    WEBUI_PORT=${WEBUI_PORT:-8080}

    echo -e "${YELLOW}更新软件包列表...${RESET}"
    sudo apt update

    echo -e "${YELLOW}安装 qBittorrent-Nox...${RESET}"
    sudo apt install -y qbittorrent-nox

    # 创建目录
    sudo mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
    sudo chown -R root:root "$APP_DIR"
    sudo chmod -R 755 "$APP_DIR"

    echo -e "${YELLOW}创建 systemd 服务文件...${RESET}"

sudo tee /etc/systemd/system/qbittorrent.service > /dev/null <<EOF
[Unit]
Description=qBittorrent Command Line Client
After=network.target

[Service]
ExecStart=/usr/bin/qbittorrent-nox --webui-port=${WEBUI_PORT} --webui-host=127.0.0.1 --profile=$CONFIG_DIR
User=root
Restart=on-failure
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable qbittorrent
    sudo systemctl restart qbittorrent

    echo -e "${GREEN}qBittorrent-Nox 安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 地址: http://127.0.0.1:${WEBUI_PORT}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -e "${YELLOW}默认密码: 查看日志获取${RESET}"
    echo -e "${GREEN}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${GREEN}下载目录: $DOWNLOAD_DIR${RESET}"
}

# 启动服务
start_qbittorrent() {
    sudo systemctl start ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 停止服务
stop_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME}
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 重启服务
restart_qbittorrent() {
    sudo systemctl restart ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 查看日志
logs_qbittorrent() {
    sudo journalctl -u ${SERVICE_NAME} -f
}

# 卸载服务
uninstall_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME}
    sudo systemctl disable ${SERVICE_NAME}
    sudo rm -f /etc/systemd/system/${SERVICE_NAME}.service
    sudo systemctl daemon-reload

    echo -e "${YELLOW}是否删除配置和下载数据？[y/N]${RESET}"
    read -r del

    if [[ "$del" == "y" || "$del" == "Y" ]]; then
        rm -rf "$APP_DIR"
        echo -e "${RED}配置和下载目录已删除${RESET}"
    fi

    echo -e "${GREEN}qBittorrent 已卸载${RESET}"
}

# 菜单
menu() {
    clear
    echo -e "${GREEN}==== qBittorrent-Nox 管理菜单 ====${RESET}"
    echo -e "${GREEN}1. 安装部署${RESET}"
    echo -e "${GREEN}2. 启动${RESET}"
    echo -e "${GREEN}3. 停止${RESET}"
    echo -e "${GREEN}4. 重启${RESET}"
    echo -e "${GREEN}5. 查看日志${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice

    case "$choice" in
        1) install_qbittorrent ;;
        2) start_qbittorrent ;;
        3) stop_qbittorrent ;;
        4) restart_qbittorrent ;;
        5) logs_qbittorrent ;;
        6) uninstall_qbittorrent ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 循环菜单
while true; do
    menu
    echo -e "${YELLOW}按回车键继续...${RESET}"
    read -r
done
