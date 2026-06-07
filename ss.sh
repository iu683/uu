#!/bin/sh
# ========================================
# qBittorrent-Nox 一键管理脚本 (Alpine 专属)
# ========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

SERVICE_NAME="qbittorrent-nox"
INIT_FILE="/etc/init.d/qbittorrent-nox"
CONF_FILE="/etc/conf.d/qbittorrent-nox"
LOG_FILE="/var/log/qbittorrent-nox.log"

APP_DIR="/opt/qbittorrent"
CONFIG_DIR="$APP_DIR/config"
DOWNLOAD_DIR="$APP_DIR/downloads"
PORT_SHOW="8080" # 固定默认端口

# 动态获取状态和版本
get_status_info() {
    if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
        status="${GREEN}已启动${RESET}"
    else
        status="${RED}未运行${RESET}"
    fi

    if command -v qbittorrent-nox > /dev/null 2>&1; then
        version=$(qbittorrent-nox --version 2>/dev/null | awk '{print $2}')
        [ -z "$version" ] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi
}

# 从日志中自动提取临时密码
get_qb_password() {
    local log_pass
    if [ -f "$LOG_FILE" ]; then
        log_pass=$(grep -E "temporary password is:|password.*session:" "$LOG_FILE" | tail -n 1 | awk '{print $NF}' | tr -d '.')
    fi
    
    if [ -n "$log_pass" ]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${RED}未找到临时密码（可能已在WebUI中修改、日志未刷新或已被清空）${RESET}"
    fi
}

# 获取公网 IP
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
    echo "无法获取公网 IP 地址"
}

# 1. 部署 qBittorrent-Nox (固定默认 8080 端口)
install_qbittorrent() {
    echo -e "${YELLOW}更新软件包列表并安装 qBittorrent-Nox...${RESET}"
    apk update
    apk add qbittorrent-nox qbittorrent-nox-openrc

    echo -e "${YELLOW}创建并配置下载目录...${RESET}"
    mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
    chown -R qbittorrent:qbittorrent "$APP_DIR"
    chmod -R 755 "$APP_DIR"

    echo -e "${YELLOW}注入官方 OpenRC 配置参数...${RESET}"
    cat <<EOF > "$CONF_FILE"
# qBittorrent-Nox 官方 OpenRC 变量配置
QB_OPTS="--webui-port=${PORT_SHOW} --profile=${CONFIG_DIR}"
EOF

    echo -e "${YELLOW}正在热补丁修复官方 OpenRC 脚本缺陷...${RESET}"
    # 1. 注入 pidfile 路径定义
    if ! grep -q "pidfile=" "$INIT_FILE"; then
        sed -i '/command=/i pidfile="/run/qbittorrent-nox.pid"' "$INIT_FILE"
    fi
    # 2. 注入日志重定向输出
    if ! grep -q "output_log=" "$INIT_FILE"; then
        sed -i '/command=/i output_log="/var/log/qbittorrent-nox.log"\nerror_log="/var/log/qbittorrent-nox.log"' "$INIT_FILE"
    fi

    echo -e "${YELLOW}正在清理旧日志并启动服务...${RESET}"
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
    rm -f "$LOG_FILE"
    
    # 创建日志文件并赋予权限
    touch "$LOG_FILE"
    chown qbittorrent:qbittorrent "$LOG_FILE"

    rc-update add "$SERVICE_NAME" default
    rc-service "$SERVICE_NAME" start

    echo -e "${YELLOW}等待服务启动并生成密码...${RESET}"
    sleep 5

    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}qBittorrent-Nox 安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${SERVER_IP}:${PORT_SHOW}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}初始密码: ${RESET}"
    get_qb_password
    echo -e "${YELLOW}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${YELLOW}下载目录: $DOWNLOAD_DIR${RESET}"
}

# 2. 更新功能
update_qbittorrent() {
    echo -e "${YELLOW}正在检查并更新 qBittorrent-Nox...${RESET}"
    apk update && apk add --upgrade qbittorrent-nox qbittorrent-nox-openrc
    # 更新后重新应用补丁
    sed -i '/command=/i pidfile="/run/qbittorrent-nox.pid"' "$INIT_FILE" 2>/dev/null
    sed -i '/command=/i output_log="/var/log/qbittorrent-nox.log"\nerror_log="/var/log/qbittorrent-nox.log"' "$INIT_FILE" 2>/dev/null
    rc-service "$SERVICE_NAME" restart
    echo -e "${GREEN}更新完成${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    echo -e "${YELLOW}正在停止并清理 qBittorrent 服务...${RESET}"
    rc-service "$SERVICE_NAME" stop 2>/dev/null
    rc-update del "$SERVICE_NAME" default 2>/dev/null
    rm -f "$CONF_FILE" "$LOG_FILE"
    rm -rf "$APP_DIR"
    echo -e "${GREEN}qBittorrent 已彻底卸载并清理目录${RESET}"
}

# 4. 启动服务
start_qbittorrent() {
    rc-service "$SERVICE_NAME" start
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 5. 停止服务
stop_qbittorrent() {
    rc-service "$SERVICE_NAME" stop
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 6. 重启服务
restart_qbittorrent() {
    rc-service "$SERVICE_NAME" restart
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 7. 查看日志
logs_qbittorrent() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${RED}错误: 日志文件还未生成或不存在！${RESET}"
        return
    fi
    echo -e "${CYAN}正在实时查看日志 (按 Ctrl+C 退出)...${RESET}"
    tail -n 50 -f "$LOG_FILE"
}

# 8. 查看节点配置
show_node_info() {
    SERVER_IP=$(get_public_ip)
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 地址 : http://${SERVER_IP}:${PORT_SHOW}${RESET}"
    echo -e "${YELLOW}默认用户名 : admin${RESET}"
    echo -ne "${YELLOW}初始密码   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

# 菜单面板
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent-Nox 管理面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${PORT_SHOW}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 qBittorrent${RESET}"
    echo -e "${GREEN}2. 更新 qBittorrent${RESET}"
    echo -e "${GREEN}3. 卸载 qBittorrent${RESET}"
    echo -e "${GREEN}4. 启动 qBittorrent${RESET}"
    echo -e "${GREEN}5. 停止 qBittorrent${RESET}"
    echo -e "${GREEN}6. 重启 qBittorrent${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_qbittorrent ;;
        2) update_qbittorrent ;;
        3) uninstall_qbittorrent ;;
        4) start_qbittorrent ;;
        5) stop_qbittorrent ;;
        6) restart_qbittorrent ;;
        7) logs_qbittorrent ;;
        8) show_node_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

# 主循环
while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
