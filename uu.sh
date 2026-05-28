#!/bin/bash

# ================== 检查 Root 权限 ==================
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[1;31m错误：本脚本包含系统级服务管理，请使用 root 用户运行！\033[0m"
    exit 1
fi

# ================== 颜色定义 ==================
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
PURPLE="\033[1;35m"
SKYBLUE="\033[1;36m"
RESET="\033[0m"

# ================== 基础环境变量 ==================
HOSTNAME=$(hostname)
USERNAME="root"
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="/root/mtp"
LOG_FILE="$WORKDIR/mtg.log"
SERVICE_FILE="/etc/systemd/system/mtproto.service"

# ================== 工具函数 ==================
red_echo() { echo -e "${RED}$1${RESET}"; }
green_echo() { echo -e "${GREEN}$1${RESET}"; }
yellow_echo() { echo -e "${YELLOW}$1${RESET}"; }
purple_echo() { echo -e "${PURPLE}$1${RESET}"; }

# 获取正在运行的端口
get_running_port() {
    if systemctl is-active --quiet mtproto.service || pgrep -x mtg >/dev/null; then
        local port=$(cat "$WORKDIR/port.txt" 2>/dev/null)
        echo "${port:-未知}"
    else
        echo "无"
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
        for url in "https://ip6.n0at.com" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

random_port() {
    shuf -i 2000-65000 -n 1
}

check_vps_port() {
    local port=$1
    while [[ -n $(lsof -i :$port 2>/dev/null) ]]; do
        red_echo "${port} 端口已经被其他程序占用，请更换端口重试。"
        read -p "请输入新端口（直接回车使用随机端口）: " port
        [[ -z $port ]] && port=$(random_port) && green_echo "使用随机端口: $port"
    done
    echo "$port"
}

install_lsof() {
    if ! command -v lsof &>/dev/null; then
        if [ -f "/etc/debian_version" ]; then
            apt update && apt install -y lsof
        elif [ -f "/etc/alpine-release" ]; then
            apk add lsof
        fi
    fi
}

# ================== Systemd 服务管理 ==================
check_systemd_status() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl is-enabled --quiet mtproto.service
    else
        false
    fi
}

set_systemd() {
    if [ ! -f "$WORKDIR/mtg" ]; then
        red_echo "未检测到核心程序，请先执行选项 1 安装！"
        return 1
    fi
    
    yellow_echo "正在配置 Systemd 系统自启服务..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProto Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKDIR
ExecStart=$WORKDIR/mtg run -b 0.0.0.0:$(cat $WORKDIR/port.txt) $SECRET --stats-bind=127.0.0.1:\$(( \$(cat $WORKDIR/port.txt) + 1 ))
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproto.service >/dev/null 2>&1
    systemctl start mtproto.service >/dev/null 2>&1
    green_echo "Systemd 服务已成功开启并设为开机自启！"
}

remove_systemd() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop mtproto.service >/dev/null 2>&1
        systemctl disable mtproto.service >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        red_echo "Systemd 开机自启服务已移除。"
    fi
}

# ================== 核心控制服务 ==================
start_proxy() {
    if [ ! -f "$WORKDIR/mtg" ]; then
        red_echo "未检测到安装文件，请先选择 1 安装。"
        return 1
    fi

    if [ -f "$SERVICE_FILE" ]; then
        systemctl start mtproto.service
        green_echo "MTProto Proxy 已通过 Systemd 成功启动！"
    else
        # 兜底旧启动方式
        local port=$(cat "$WORKDIR/port.txt" 2>/dev/null)
        nohup ./mtg run -b 0.0.0.0:$port "$SECRET" --stats-bind=127.0.0.1:$((port + 1)) >> "$LOG_FILE" 2>&1 &
        green_echo "MTProto Proxy 后台启动成功！"
    fi
}

stop_proxy() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop mtproto.service >/dev/null 2>&1
    fi
    pkill -9 mtg >/dev/null 2>&1
    green_echo "MTProto Proxy 已成功停止。"
}

show_config() {
    if [ ! -f "$WORKDIR/link.txt" ]; then
        red_echo "未找到连接配置，请确保已成功安装。"
    else
        purple_echo "\n==== 当前 MTProto 连接配置 ===="
        cat "$WORKDIR/link.txt"
        echo "================================"
    fi
}

# ================== 安装与配置修改 ==================
download_and_run_mtg() {
    local arch="amd64"
    cmd=$(uname -m)
    if [ "$cmd" == "386" ]; then arch="386"; fi
    if [ "$cmd" == "arm" ]; then arch="arm"; fi
    if [ "$cmd" == "aarch64" ]; then arch="arm64"; fi

    mkdir -p "$WORKDIR"
    stop_proxy

    yellow_echo "正在下载 mtg 核心组件..."
    wget -q -O "${WORKDIR}/mtg" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    
    if [ ! -s "${WORKDIR}/mtg" ]; then
        red_echo "下载核心失败，请检查网络！"
        return 1
    fi
    
    chmod +x "${WORKDIR}/mtg"
    echo "$MTP_PORT" > "$WORKDIR/port.txt"
    
    # 默认直接生成并用 systemd 启动
    set_systemd
    return 0
}

core_install() {
    purple_echo "正在配置 MTProto 代理端口...\n"
    
    install_lsof
    read -p "请输入 MTProto 代理端口 (回车使用随机端口): " user_port
    [[ -z $user_port ]] && user_port=$(random_port)
    MTP_PORT=$(check_vps_port "$user_port")
    IP1=$(get_public_ip)

    if download_and_run_mtg; then
        purple_echo "\n🎉 MTProto 安装/修改成功！"
        LINKS="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
        green_echo "$LINKS\n"
        echo -e "$LINKS" > "${WORKDIR}/link.txt"
        
        # 移除可能残留的旧 crontab 任务，统一走 systemd
        crontab -l 2>/dev/null | grep -Fv "restart.sh" | crontab - >/dev/null 2>&1
    fi
}

# ================== 主菜单循环 ==================
while true; do
    clear
    # 状态与端口动态获取
    if systemctl is-active --quiet mtproto.service || pgrep -x mtg >/dev/null; then
        status_display="${GREEN}正在运行${RESET}"
    else
        status_display="${RED}已停止${RESET}"
    fi
    
    # 获取自启状态
    if check_systemd_status; then
        cron_display="${GREEN}开机自启[已开启]${RESET}"
    else
        cron_display="${RED}开机自启[已关闭]${RESET}"
    fi

    port_display=$(get_running_port)

    # 打印精美面板样式
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        MTProto Proxy 管理面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status_display}  (${cron_display})"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 MTProto Proxy"
    echo -e "${GREEN}2.${RESET} 修改配置 (换端口/重装)"
    echo -e "${GREEN}3.${RESET} 卸载 MTProto Proxy"
    echo -e "${GREEN}4.${RESET} 启动 MTProto Proxy"
    echo -e "${GREEN}5.${RESET} 停止 MTProto Proxy"
    echo -e "${GREEN}6.${RESET} 重启 MTProto Proxy"
    echo -e "${GREEN}7.${RESET} 查看日志 (最新50行)"
    echo -e "${GREEN}8.${RESET} 查看连接配置 (分享链接)"
    echo -e "${GREEN}0.${RESET} 退出"
    echo -e "${GREEN}================================${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET} )" choice

    case $choice in
        1|2)
            clear; core_install; read -p "按回车返回菜单..." ;;
        3)
            clear
            remove_systemd; stop_proxy; rm -rf "$WORKDIR"
            clear; red_echo "MTProto 已彻底从系统中卸载！"; read -p "按回车返回菜单..." ;;
        4)
            clear; start_proxy; read -p "按回车返回菜单..." ;;
        5)
            clear; stop_proxy; read -p "按回车返回菜单..." ;;
        6)
            clear
            if [ -f "$SERVICE_FILE" ]; then
                systemctl restart mtproto.service
                green_echo "MTProto Proxy 重启成功！"
            else
                stop_proxy; sleep 1; start_proxy
            fi
            read -p "按回车返回菜单..." ;;
        7)
            clear
            if [ -f "$LOG_FILE" ]; then
                purple_echo "=== 正在查看最新 50 行运行日志 ==="
                tail -n 50 "$LOG_FILE"
                echo "=================================="
            else
                yellow_echo "暂无日志文件。"
            fi
            read -p "按回车返回菜单..." ;;
        8)
            clear; show_config; read -p "按回车返回菜单..." ;;
        0)
            exit 0 ;;
        *)
            red_echo "无效输入！" ; sleep 1 ;;
    esac
done
