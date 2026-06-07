#!/bin/sh
# ========================================
# qBittorrent-Nox 一键管理脚本 (Alpine 专属版)
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
INIT_FILE="/etc/init.d/$SERVICE_NAME"
CONF_FILE="/etc/conf.d/$SERVICE_NAME"
LOG_FILE="/var/log/qbittorrent.log"

# 动态获取状态、版本和端口
get_status_info() {
    # 1. 检测运行状态
    if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
        status="${GREEN}已启动${RESET}"
    else
        status="${RED}未运行${RESET}"
    fi

    # 2. 检测版本号
    if command -v qbittorrent-nox &> /dev/null; then
        version=$(qbittorrent-nox --version 2>/dev/null | awk '{print $2}')
        [ -z "$version" ] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi

    # 3. 检测 WebUI 端口
    if [ -f "$CONF_FILE" ]; then
        port_show=$(grep -oE 'WEBUI_PORT="[0-9]+"' "$CONF_FILE" | cut -d'"' -f2)
        [ -z "$port_show" ] && port_show="8080"
    else
        port_show="N/A"
    fi
}

# 从日志中自动提取临时密码
get_qb_password() {
    local log_pass
    if [ -f "$LOG_FILE" ]; then
        # 抓取包含密码的核心日志行，并提取最后一个单词
        log_pass=$(grep -E "temporary password is:|password.*session:" "$LOG_FILE" | tail -n 1 | awk '{print $NF}' | tr -d '.')
    fi
    
    if [ -n "$log_pass" ]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${RED}未找到临时密码（可能已在WebUI中修改或日志已清空）${RESET}"
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。"
}

# 检查并创建目录
mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
# Alpine 默认没有 sudo，这里直接假设以 root 运行（Alpine 容器/系统常用做法）
CURRENT_USER=$(whoami)
chown -R "$CURRENT_USER":"$CURRENT_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# 1. 部署 qBittorrent-Nox
install_qbittorrent() {
    echo -ne "${YELLOW}请输入你想要设置的 WebUI 端口号 [默认: 8080]: ${RESET}"
    read -r custom_port
    [ -z "$custom_port" ] && custom_port="8080"

    if ! echo "$custom_port" | grep -qE '^[0-9]+$'; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}更新软件包列表并安装 qBittorrent-Nox...${RESET}"
    # Alpine 需要确保开启了 community 仓库才能安装 qbittorrent-nox
    apk update
    apk add qbittorrent-nox

    echo -e "${YELLOW}创建 OpenRC 配置文件...${RESET}"
    cat <<EOF > "$CONF_FILE"
# qBittorrent-Nox OpenRC 配置
WEBUI_PORT="${custom_port}"
PROFILE_DIR="${CONFIG_DIR}"
DOWNLOAD_DIR="${DOWNLOAD_DIR}"
RUN_AS="${CURRENT_USER}"
LOG_FILE="${LOG_FILE}"
EOF

    echo -e "${YELLOW}创建 OpenRC 服务脚本...${RESET}"
    cat <<'EOF' > "$INIT_FILE"
#!/sbin/openrc-run

description="qBittorrent Command Line Client"
supervisor="supervisord" # 使用 Alpine 自带的 supervisor 模式来更好地控制后台进程和日志

command="/usr/bin/qbittorrent-nox"
command_args="--webui-port=${WEBUI_PORT} --profile=${PROFILE_DIR}"
command_user="${RUN_AS}"
directory="${DOWNLOAD_DIR}"

output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}

start_pre() {
    # 确保日志文件存在且权限正确
    touch "${LOG_FILE}"
    chown "${RUN_AS}":"${RUN_AS}" "${LOG_FILE}"
}
EOF

    chmod +x "$INIT_FILE"

    echo -e "${YELLOW}正在启动服务并设置开机自启...${RESET}"
    rc-update add qbittorrent default
    rc-service qbittorrent start

    echo -e "${YELLOW}等待服务启动并生成密码...${RESET}"
    sleep 3

    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}qBittorrent-Nox 安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${SERVER_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}初始密码: ${RESET}"
    get_qb_password
    echo -e "${YELLOW}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${YELLOW}下载目录: $DOWNLOAD_DIR${RESET}"
}

# 2. 更新功能
update_qbittorrent() {
    echo -e "${YELLOW}正在检查并更新 qBittorrent-Nox...${RESET}"
    apk update && apk add --upgrade qbittorrent-nox
    rc-service qbittorrent restart
    echo -e "${GREEN}更新完成${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    rc-service qbittorrent stop 2>/dev/null
    rc-update del qbittorrent default 2>/dev/null
    rm -f "$INIT_FILE" "$CONF_FILE" "$LOG_FILE"
    rm -rf "$APP_DIR"
    echo -e "${GREEN}qBittorrent 已卸载${RESET}"
}

# 4. 修改端口配置
edit_config() {
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}错误: 未检测到配置文件，请先安装 qBittorrent！${RESET}"
        return
    fi

    get_status_info
    echo -e "${CYAN}当前 WebUI 端口为: ${port_show}${RESET}"
    echo -ne "${YELLOW}请输入新的 WebUI 端口号: ${RESET}"
    read -r new_port

    if [ -z "$new_port" ] || ! echo "$new_port" | grep -qE '^[0-9]+$'; then
        echo -e "${RED}操作取消或输入错误：端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在修改端口为 ${new_port}...${RESET}"
    sed -i "s/WEBUI_PORT=\"[0-9]*\"/WEBUI_PORT=\"${new_port}\"/g" "$CONF_FILE"
    
    echo -e "${YELLOW}正在重启服务...${RESET}"
    rc-service "$SERVICE_NAME" restart
    
    echo -e "${GREEN}端口修改成功！当前新端口为: ${new_port}${RESET}"
}

# 5. 启动服务
start_qbittorrent() {
    rc-service ${SERVICE_NAME} start
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 6. 停止服务
stop_qbittorrent() {
    rc-service ${SERVICE_NAME} stop
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 7. 重启服务
restart_qbittorrent() {
    rc-service ${SERVICE_NAME} restart
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 8. 查看日志
logs_qbittorrent() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${RED}错误: 日志文件不存在！${RESET}"
        return
    fi
    echo -e "${CYAN}正在实时查看日志 (按 Ctrl+C 退出)...${RESET}"
    tail -n 50 -f "$LOG_FILE"
}

# 9. 查看节点配置
show_node_info() {
    SERVER_IP=$(get_public_ip)
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 地址 : http://${SERVER_IP}:${port_show}${RESET}"
    echo -e "${YELLOW}默认用户名 : admin${RESET}"
    echo -ne "${YELLOW}初始密码   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

# 菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent-Nox 管理面板    ${RESET}"
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

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
