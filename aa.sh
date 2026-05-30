#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
PURPLE="\033[1;35m"
SKYBLUE="\033[1;36m"
RESET="\033[0m"

# ================== 基础环境变量 ==================
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | awk '{print $1}' | head -c 32)}
WORKDIR="$HOME/mtp"
CRON_CMD="@reboot sleep 30 && /bin/bash $WORKDIR/restart.sh >/dev/null 2>&1"
LOG_FILE="$WORKDIR/mtg.log"

# ================== 工具函数 ==================
red_echo() { echo -e "${RED}$1${RESET}"; }
green_echo() { echo -e "${GREEN}$1${RESET}"; }
yellow_echo() { echo -e "${YELLOW}$1${RESET}"; }
purple_echo() { echo -e "${PURPLE}$1${RESET}"; }

# 获取最准确的当前运行 PID
get_mtg_pid() {
    local pid=$(pidof mtg)
    if [[ -z "$pid" ]]; then
        pid=$(ps -ef 2>/dev/null | grep 'mtg run' | grep -v grep | awk '{print $1}')
    fi
    echo "$pid"
}

# 获取面板状态显示 (严格在函数内用 local)
get_status_display() {
    local current_pid=$(get_mtg_pid)
    local saved_port=$(cat "$WORKDIR/port.txt" 2>/dev/null)
    local is_listening=""
    [[ -n "$saved_port" ]] && is_listening=$(netstat -an 2>/dev/null | grep -E "[:\.]${saved_port} " | grep -i "listen")

    if [[ -n "$current_pid" || -n "$is_listening" ]]; then
        echo -e "${GREEN}正在运行${RESET}"
    else
        echo -e "${RED}已停止${RESET}"
    fi
}

# 获取正在运行的端口
get_running_port() {
    local pid=$(get_mtg_pid)
    local port=""
    if [[ -n "$pid" ]]; then
        port=$(netstat -anp 2>/dev/null | grep "$pid/" | grep -i "listen" | awk '{print $4}' | cut -d':' -f2 | head -n 1)
        [[ -z "$port" && -f "$WORKDIR/port.txt" ]] && port=$(cat "$WORKDIR/port.txt")
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
    echo "无法获取公网 IP"
}

random_port() {
    awk 'BEGIN{srand(); print int(rand()*(65000-2000+1))+2000}'
}

# 彻底修复输出污染的端口检查函数
check_vps_port() {
    local port=$1
    while true; do
        # 仅仅把提示打印到标准错误(>&2)，确保标准输出只返回纯数字端口
        if [[ -n $(netstat -an 2>/dev/null | grep -E "[:\.]${port} " | grep -i "listen") ]]; then
            echo -e "${RED}${port} 端口已经被其他程序占用，请更换端口重试。${RESET}" >&2
            read -p "请输入新端口（回车使用随机端口）: " port
            if [[ -z $port ]]; then
                port=$(random_port)
                echo -e "${GREEN}使用随机端口: $port${RESET}" >&2
            fi
        else
            break
        fi
    done
    echo "$port"
}

install_alpine_deps() {
    local update_done=0
    if ! command -v bash &>/dev/null; then apk update && update_done=1 && apk add bash; fi
    if ! command -v curl &>/dev/null; then [[ $update_done -eq 0 ]] && apk update && update_done=1; apk add curl; fi
}

# ================== Crontab 管理 ==================
check_cron_status() {
    crontab -l 2>/dev/null | grep -q "restart.sh"
}

set_cron() {
    if ! check_cron_status; then
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    fi
    rc-service crond start >/dev/null 2>&1 || crond -b >/dev/null 2>&1
}

remove_cron() {
    crontab -l 2>/dev/null | grep -v "restart.sh" | crontab -
}

# ================== 核心控制服务 ==================
start_proxy() {
    local pid=$(get_mtg_pid)
    if [[ -n "$pid" ]]; then
        yellow_echo "MTProto Proxy 已经在运行中 (PID: $pid)。"
        return 0
    fi
    
    if [ ! -f "$WORKDIR/mtg" ]; then
        red_echo "未检测到安装文件，请先选择 1 安装。"
        return 1
    fi

    local port=$(cat "$WORKDIR/port.txt" 2>/dev/null)
    if [[ -z "$port" || "$port" == "无" ]]; then
        red_echo "未检测到配置端口，请重新安装或修改配置。"
        return 1
    fi

    cd "$WORKDIR" || return
    local stats_p=$((port + 1))
    nohup ./mtg run -b 0.0.0.0:$port "$SECRET" --stats-bind=127.0.0.1:${stats_p} >> "$LOG_FILE" 2>&1 &
    sleep 1
    green_echo "MTProto Proxy 启动指令已发送！"
}

stop_proxy() {
    # 针对 Alpine 的强杀组合拳
    local pids=$(pidof mtg || ps -ef | grep 'mtg run' | grep -v grep | awk '{print $1}')
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -9 >/dev/null 2>&1
    fi
    pkill -9 -f "mtg run" >/dev/null 2>&1
    pkill -9 mtg >/dev/null 2>&1
    green_echo "MTProto Proxy"
}

show_config() {
    if [ ! -f "$WORKDIR/link.txt" ]; then
        red_echo "未找到连接配置，请确保已成功安装。"
    else
        purple_echo "==== 当前 MTProto 连接配置 ===="
        cat "$WORKDIR/link.txt"
    fi
}

# ================== 安装与配置修改 ==================
download_and_run_mtg() {
    local arch="amd64"
    cmd=$(uname -m)
    if [ "$cmd" == "386" ] || [ "$cmd" == "i686" ]; then arch="386"; fi
    if [ "$cmd" == "armv7l" ] || [ "$cmd" == "armhf" ]; then arch="arm"; fi
    if [ "$cmd" == "aarch64" ] || [ "$cmd" == "arm64" ]; then arch="arm64"; fi

    mkdir -p "$WORKDIR"
    stop_proxy

    yellow_echo "正在下载 mtg 专属 Alpine 静态核心组件..."
    wget -q -O "${WORKDIR}/mtg" "https://github.com/9600/mtg/releases/download/v2.1.7/mtg-linux-$arch"
    
    if [ ! -s "${WORKDIR}/mtg" ]; then
        wget -q -O "${WORKDIR}/mtg" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    fi
    
    if [ ! -s "${WORKDIR}/mtg" ]; then
        red_echo "下载核心失败，请检查网络！"
        return 1
    fi
    
    chmod +x "${WORKDIR}/mtg"
    echo "$MTP_PORT" > "$WORKDIR/port.txt"
    cd "$WORKDIR" || return

    # 启动服务
    local stats_port=$((MTP_PORT + 1))
    nohup ./mtg run -b 0.0.0.0:$MTP_PORT "$SECRET" --stats-bind=127.0.0.1:${stats_port} >> "$LOG_FILE" 2>&1 &
    
    # 创建守护/重启脚本
    cat > "${WORKDIR}/restart.sh" <<EOF
#!/bin/bash
pkill -9 -f "mtg run" >/dev/null 2>&1
pkill -9 mtg >/dev/null 2>&1
cd ${WORKDIR}
nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:${stats_port} >> ${LOG_FILE} 2>&1 &
EOF
    chmod +x "${WORKDIR}/restart.sh"
    return 0
}

core_install() {
    install_alpine_deps
    purple_echo "正在配置 MTProto 代理端口...\n"
    
    read -p "请输入 MTProto 代理端口 (回车使用随机端口): " user_port
    [[ -z $user_port ]] && user_port=$(random_port)
    
    # 核心修复点：通过 check_vps_port 获取纯净的端口数字
    MTP_PORT=$(check_vps_port "$user_port")
    IP1=$(get_public_ip)

    if download_and_run_mtg; then
        sleep 1
        purple_echo "\n🎉 MTProto 安装/修改完成！"
        LINKS="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
        green_echo "$LINKS\n"
        echo -e "$LINKS" > "${WORKDIR}/link.txt"
        
        read -p "是否同时将MTProto加入开机自启（Crontab）？[回车默认加入,Y/n]: " choice_cron
        case "$choice_cron" in
            [nN][oO]|[nN]) remove_cron ;;
            *) set_cron ;;
        esac
    fi
}

# ================== 主菜单循环 ==================
while true; do
    clear
    
    # 严格调用函数获取状态和端口，杜绝在主循环体直接使用 local
    status_display=$(get_status_display)
    port_display=$(get_running_port)
    
    if check_cron_status; then
        cron_display="${GREEN}已开启${RESET}"
    else
        cron_display="${RED}已关闭${RESET}"
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     MTProto Proxy 管理面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态     :${RESET} ${status_display}"
    echo -e "${GREEN}端口     :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}开机自启 :${RESET} ${cron_display}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 MTProto${RESET}"
    echo -e "${GREEN}2. 修改配置${RESET}"
    echo -e "${GREEN}3. 卸载 MTProto${RESET}"
    echo -e "${GREEN}4. 启动 MTProto${RESET}"
    echo -e "${GREEN}5. 停止 MTProto${RESET}"
    echo -e "${GREEN}6. 重启 MTProto${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看连接配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    read -p "$(echo -e ${GREEN}请选择:${RESET} )" choice

    case $choice in
        1|2)
            clear; core_install; read -p "按回车返回菜单..." ;;
        3)
            clear
            stop_proxy; remove_cron; rm -rf "$WORKDIR"
            red_echo "MTProto 已彻底从系统中卸载！"; read -p "按回车返回菜单..." ;;
        4)
            clear; start_proxy; read -p "按回车返回菜单..." ;;
        5)
            clear; stop_proxy; read -p "按回车返回菜单..." ;;
        6)
            clear; stop_proxy; sleep 1; start_proxy; read -p "按回车返回菜单..." ;;
        7)
            clear
            if [ -f "$LOG_FILE" ]; then
                purple_echo "=== 正在查看最新 50 行运行日志 ==="
                tail -n 50 "$LOG_FILE"
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
