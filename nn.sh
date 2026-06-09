#!/bin/bash
# ========================================
# qBittorrent-Nox (最新二进制+自动密码提取) 一键脚本
# ========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

SERVICE_NAME="qbittorrent"
APP_DIR="/opt/qbittorrent"
BIN_FILE="$APP_DIR/qbittorrent-nox"
CONFIG_DIR="$APP_DIR/config"
DOWNLOAD_DIR="$APP_DIR/downloads"
SERVICE_FILE="/etc/systemd/system/qbittorrent.service"

# 动态获取状态、本地版本、IP和端口
get_status_info() {
    # 1. 检测运行状态
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        status="${GREEN}已启动${RESET}"
    else
        status="${RED}未运行${RESET}"
    fi

    # 2. 检测本地已安装的版本号
    if [[ -f "$BIN_FILE" ]]; then
        version=$("$BIN_FILE" --version 2>/dev/null | awk '{print $2}')
        [[ -z "$version" ]] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi

    # 3. 检测 WebUI 端口和绑定 IP
    if [[ -f "$SERVICE_FILE" ]]; then
        port_show=$(grep -oE -- '--webui-port=[0-9]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$port_show" ]] && port_show="8080"
        
        ip_show=$(grep -oE -- '--webui-listen-address=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$ip_show" ]] && ip_show="0.0.0.0 (全部)"
    else
        port_show="N/A"
        ip_show="N/A"
    fi
}

# 核心：从 journalctl 日志中自动过滤并精准提取临时密码
get_qb_password() {
    local log_line log_pass
    # 兼容新旧版本不同的日志提示文本
    log_line=$(sudo journalctl -u "$SERVICE_NAME" --no-pager | grep -E "temporary password is:|password.*session:" | tail -n 1)
    
    if [[ -n "$log_line" ]]; then
        # 提取这行的最后一个单词（即密码本身）并剔除尾部的句号
        log_pass=$(echo "$log_line" | awk '{print $NF}' | tr -d '.')
    fi
    
    if [[ -n "$log_pass" ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${RED}未找到临时密码（可能已在WebUI中修改，或日志已被清空）${RESET}"
    fi
}

# 自动获取 GitHub 官方最新的稳定版 Release Tag 和下载直链
get_latest_release() {
    echo -e "${YELLOW}正在检测 GitHub 官方最新版本...${RESET}"
    local release_json
    release_json=$(curl -s https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest)
    
    if [[ -z "$release_json" ]] || [[ "$release_json" == *"message"* ]]; then
        echo -e "${RED}错误: 无法获取 GitHub Release 信息，请检查网络环境。${RESET}"
        return 1
    fi

    LATEST_TAG=$(echo "$release_json" | grep '"tag_name":' | head -n 1 | awk -F '"' '{print $4}')
    DOWNLOAD_URL=$(echo "$release_json" | grep '"browser_download_url":' | grep 'x86_64-pc-linux-gnu_static' | head -n 1 | awk -F '"' '{print $4}')

    if [[ -z "$DOWNLOAD_URL" ]]; then
        DOWNLOAD_URL=$(echo "$release_json" | grep '"browser_download_url":' | grep 'static' | head -n 1 | awk -F '"' '{print $4}')
    fi

    if [[ -z "$LATEST_TAG" || -z "$DOWNLOAD_URL" ]]; then
        echo -e "${RED}错误: 无法解析出有效的官方下载链接！${RESET}"
        return 1
    fi
    return 0
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "127.0.0.1"
}

# 基础目录环境初始化
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DOWNLOAD_DIR"
chown -R $(whoami):$(whoami) "$APP_DIR"
chmod -R 755 "$APP_DIR"

# 1. 部署最新版 qBittorrent-Nox (支持自定义绑定 IP/端口 + 密码提取)
install_qbittorrent() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}正在安装必要依赖 curl...${RESET}"
        sudo apt update && sudo apt install -y curl
    fi

    get_latest_release || return

    echo -ne "${YELLOW}请输入你想要绑定的 WebUI IP [默认: 0.0.0.0 (监听所有IP)]: ${RESET}"
    read -r custom_ip
    [[ -z "$custom_ip" ]] && custom_ip="0.0.0.0"

    echo -ne "${YELLOW}请输入你想要设置的 WebUI 端口号 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在从 GitHub 下载最新版 (${LATEST_TAG}) 静态二进制文件...${RESET}"
    sudo curl -L -o "$BIN_FILE" "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 || ! -s "$BIN_FILE" ]]; then
        echo -e "${RED}错误: 下载失败，请检查网络连通性。${RESET}"
        return
    fi

    chmod +x "$BIN_FILE"
    chown $(whoami):$(whoami) "$BIN_FILE"

    echo -e "${YELLOW}创建 systemd 服务文件...${RESET}"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=qBittorrent Command Line Client (Latest Binary)
After=network.target

[Service]
ExecStart=${BIN_FILE} --webui-listen-address=${custom_ip} --webui-port=${custom_port} --profile=$CONFIG_DIR
User=$(whoami)
Restart=on-failure
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start qbittorrent
    sudo systemctl enable qbittorrent

    echo -e "${YELLOW}等待服务拉起并同步日志...${RESET}"
    sleep 4

    if [[ "$custom_ip" == "0.0.0.0" ]]; then
        SHOW_IP=$(get_public_ip)
    else
        SHOW_IP=$custom_ip
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}qBittorrent-Nox 二进制最新版安装成功并已运行!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${SHOW_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}初始随机密码: ${RESET}"
    get_qb_password
    echo -e "${YELLOW}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${YELLOW}下载目录: $DOWNLOAD_DIR${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 2. 自动检查并更新到最新版
update_qbittorrent() {
    get_latest_release || return

    echo -e "${YELLOW}正在停止现有服务...${RESET}"
    sudo systemctl stop "$SERVICE_NAME"
    
    echo -e "${YELLOW}正在下载最新版 (${LATEST_TAG}) 二进制文件并覆盖...${RESET}"
    sudo curl -L -o "$BIN_FILE" "$DOWNLOAD_URL"
    chmod +x "$BIN_FILE"
    
    echo -e "${YELLOW}正在重新启动服务...${RESET}"
    sudo systemctl start "$SERVICE_NAME"
    echo -e "${GREEN}成功自动升级/修复至官方最新版 (${LATEST_TAG})！${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME} 2>/dev/null
    sudo systemctl disable ${SERVICE_NAME} 2>/dev/null
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    rm -rf "$APP_DIR"
    echo -e "${GREEN}qBittorrent 二进制版及数据已完全清除${RESET}"
}

# 4. 修改端口和 IP 配置
edit_config() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到服务文件，请先安装 qBittorrent！${RESET}"
        return
    fi

    get_status_info
    echo -e "${CYAN}当前绑定的 IP 为: ${ip_show}${RESET}"
    echo -e "${CYAN}当前 WebUI 端口为: ${port_show}${RESET}"
    echo -e "${YELLOW}================================${RESET}"
    
    echo -ne "${YELLOW}请输入新的绑定 IP (回车保持不变): ${RESET}"
    read -r new_ip
    
    echo -ne "${YELLOW}请输入新的 WebUI 端口号 (回车保持不变): ${RESET}"
    read -r new_port

    # 修改 IP
    if [[ -n "$new_ip" ]]; then
        sudo sed -i "s/--webui-listen-address=[^ ]*/--webui-listen-address=${new_ip}/g" "$SERVICE_FILE"
        echo -e "${GREEN}IP 成功调整为: ${new_ip}${RESET}"
    fi

    # 修改端口
    if [[ -n "$new_port" ]]; then
        if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误：端口必须是纯数字！修改被取消。${RESET}"
        else
            sudo sed -i "s/--webui-port=[0-9]*/--webui-port=${new_port}/g" "$SERVICE_FILE"
            echo -e "${GREEN}端口成功调整为: ${new_port}${RESET}"
        fi
    fi
    
    echo -e "${YELLOW}正在重载配置并重启服务...${RESET}"
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}配置已生效！${RESET}"
}

# 5, 6, 7. 常规运维服务控制
start_qbittorrent() {
    sudo systemctl start ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}
stop_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME}
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}
restart_qbittorrent() {
    sudo systemctl restart ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 8. 查看实时日志
logs_qbittorrent() {
    echo -e "${CYAN}正在查看实时跟踪日志 (按 Ctrl+C 退出)...${RESET}"
    sudo journalctl -u ${SERVICE_NAME} -n 50 -f
}

# 9. 查看节点配置
show_node_info() {
    get_status_info
    local current_ip=$(grep -oE -- '--webui-listen-address=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
    [[ -z "$current_ip" || "$current_ip" == "0.0.0.0" ]] && current_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}绑定 IP    : ${ip_show}${RESET}"
    echo -e "${YELLOW}WebUI 地址 : http://${current_ip}:${port_show}${RESET}"
    echo -e "${YELLOW}默认用户名 : admin${RESET}"
    echo -ne "${YELLOW}初始随机密码: ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

# 菜单架构
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent-Nox 管理面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}绑定IP :${RESET} ${YELLOW}${ip_show}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 自动安装 qBittorrent (GitHub最新二进制版)${RESET}"
    echo -e "${GREEN}2. 自动检查并升级最新版${RESET}"
    echo -e "${GREEN}3. 卸载 qBittorrent${RESET}"
    echo -e "${GREEN}4. 修改 IP/端口 配置${RESET}"
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

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
