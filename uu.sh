#!/bin/bash
# ========================================
# qBittorrent-Nox 一键管理脚本 
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
SERVICE_FILE="/etc/systemd/system/qbittorrent.service"

# 动态获取状态、版本和端口
get_status_info() {
    # 1. 检测运行状态
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        status="${GREEN}已启动 (Running)${RESET}"
    else
        status="${RED}未运行 (Stopped)${RESET}"
    fi

    # 2. 检测版本号
    if command -v qbittorrent-nox &> /dev/null; then
        version=$(qbittorrent-nox --version 2>/dev/null | awk '{print $2}')
        [[ -z "$version" ]] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi

    # 3. 检测 WebUI 端口
    if [[ -f "$SERVICE_FILE" ]]; then
        port_show=$(grep -oE -- '--webui-port=[0-9]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$port_show" ]] && port_show="8080"
    else
        port_show="N/A"
    fi
}

# 从日志中自动提取临时密码

get_qb_password() {
    local log_pass
    # 关键词改为匹配 "password" 和 "session:" 或 "is:"，并精准提取最后一串字符
    log_pass=$(sudo journalctl -u "$SERVICE_NAME" --no-pager | grep -E "password.*session:|temporary password is:" | tail -n 1 | awk -F ': ' '{print $2}' | tr -d ' ')
    
    # 如果上面那种格式没切出来，尝试直接拿整行的最后一个单词
    if [[ -z "$log_pass" ]]; then
        log_pass=$(sudo journalctl -u "$SERVICE_NAME" --no-pager | grep -E "password.*session:|temporary password is:" | tail -n 1 | awk '{print $NF}')
    fi

    if [[ -n "$log_pass" && "$log_pass" != "preferences." ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${RED}未找到临时密码（可能已在WebUI中修改或日志已清空）${RESET}"
    fi
}

get_public_ip() {
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
    echo "无法获取公网 IP 地址。"
}

# 检查并创建目录
mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
chown -R $(whoami):$(whoami) "$APP_DIR"
chmod -R 755 "$APP_DIR"

# 1. 部署 qBittorrent-Nox (支持自定义端口)
install_qbittorrent() {
    echo -ne "${YELLOW}请输入你想要设置的 WebUI 端口号 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 简单校验是否为纯数字
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}更新软件包列表...${RESET}"
    sudo apt update
    echo -e "${YELLOW}安装 qBittorrent-Nox...${RESET}"
    sudo apt install -y qbittorrent-nox

    echo -e "${YELLOW}创建 systemd 服务文件 (端口: ${custom_port})...${RESET}"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=qBittorrent Command Line Client
After=network.target

[Service]
ExecStart=/usr/bin/qbittorrent-nox --webui-port=${custom_port} --profile=$CONFIG_DIR
User=$(whoami)
Restart=on-failure
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start qbittorrent
    sudo systemctl enable qbittorrent

    echo -e "${YELLOW}等待服务启动并生成密码...${RESET}"
    sleep 3

    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}qBittorrent-Nox 安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${SERVER_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}自动提取初始密码: ${RESET}"
    get_qb_password
    echo -e "${GREEN}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${GREEN}下载目录: $DOWNLOAD_DIR${RESET}"
}

# 2. 更新功能
update_qbittorrent() {
    echo -e "${YELLOW}正在检查并更新 qBittorrent-Nox...${RESET}"
    sudo apt update && sudo apt --only-upgrade install -y qbittorrent-nox
    sudo systemctl restart qbittorrent
    echo -e "${GREEN}更新尝试完成${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME} 2>/dev/null
    sudo systemctl disable ${SERVICE_NAME} 2>/dev/null
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    
    echo -e "${YELLOW}是否删除配置和下载数据？[y/N]${RESET}"
    read -r del
    if [[ "$del" == "y" || "$del" == "Y" ]]; then
        rm -rf "$APP_DIR"
        echo -e "${RED}配置和下载目录已删除${RESET}"
    fi
    echo -e "${GREEN}qBittorrent 已卸载${RESET}"
}

# 4. 修改端口配置
edit_config() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到服务文件，请先安装 qBittorrent！${RESET}"
        return
    fi

    get_status_info
    echo -e "${CYAN}当前 WebUI 端口为: ${port_show}${RESET}"
    echo -ne "${YELLOW}请输入新的 WebUI 端口号: ${RESET}"
    read -r new_port

    if [[ -z "$new_port" ]] || ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}操作取消或输入错误：端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在修改端口为 ${new_port}...${RESET}"
    # 使用 sed 替换服务文件里的端口
    sudo sed -i "s/--webui-port=[0-9]*/--webui-port=${new_port}/g" "$SERVICE_FILE"
    
    echo -e "${YELLOW}正在重载系统配置并重启服务...${RESET}"
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"
    
    echo -e "${GREEN}端口修改成功！当前新端口为: ${new_port}${RESET}"
}

# 5. 启动服务
start_qbittorrent() {
    sudo systemctl start ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 6. 停止服务
stop_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME}
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 7. 重启服务
restart_qbittorrent() {
    sudo systemctl restart ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 8. 查看日志
logs_qbittorrent() {
    echo -e "${CYAN}正在实时查看日志 (按 Ctrl+C 退出)...${RESET}"
    sudo journalctl -u ${SERVICE_NAME} -n 50 -f
}

# 9. 查看节点配置
show_node_info() {
    SERVER_IP=$(get_public_ip)
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}WebUI 地址 : http://${SERVER_IP}:${port_show}${RESET}"
    echo -e "${CYAN}默认用户名 : admin${RESET}"
    echo -ne "${CYAN}初始密码   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

# 菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     qBittorrent-Nox 管理面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 qBittorrent${RESET}"
    echo -e "${GREEN}2. 更新 qBittorrent${RESET}"
    echo -e "${GREEN}3. 卸载 qBittorrent${RESET}"
    echo -e "${GREEN}4. 修改端口配置${RESET}"
    echo -e "${GREEN}5. 启动 qBittorrent${RESET}"
    echo -e "${GREEN}6. 停止 qBittorrent${RESET}"
    echo -e "${GREEN}7. 重启 qBittorrent${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_qbittorrent ;;
        2) update_qbittorrent ;;
        3) uninstall_qbittorrent ;;
        4) edit_config ;;
        5) start_qbittorrent ;;
        6) stop_qbittorrent ;;
        7) restart_qbittorrent ;;
        8) logs_qbittorrent ;;
        9) show_node_info ;;
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
