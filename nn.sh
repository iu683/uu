#!/bin/bash
# ==========================================
# iperf3 VPS 双向测速管理器 终极稳定版
# 作者优化版（双向 + 自定义带宽 + 日志）
# ==========================================

APP_DIR="/opt/iperf3"
LOGFILE="$APP_DIR/iperf3_results.log"
SERVER_PID_FILE="$APP_DIR/iperf3_server.pid"

PORT=5201
TIME=30
UDP_BANDWIDTH="1G"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

#################################
init_dir() {
    mkdir -p "$APP_DIR"
}

#################################
install_iperf3() {
    if ! command -v iperf3 &>/dev/null; then
        echo "正在安装 iperf3..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y iperf3
        elif command -v yum &>/dev/null; then
            yum install -y iperf3
        elif command -v apk &>/dev/null; then
            apk add iperf3
        else
            echo "❌ 无法自动安装 iperf3"
            exit 1
        fi
    fi
}

#################################
log_result() {
    {
        echo "================================"
        echo "时间: $(date '+%F %T')"
        echo "$1"
        echo "================================"
        echo ""
    } >> "$LOGFILE"
}

#################################
parse_tcp() {
    echo "$1" | grep receiver | tail -1 | awk '{print $(NF-1),$NF}'
}

parse_udp() {
    LINE=$(echo "$1" | grep receiver | tail -1)
    BW=$(echo "$LINE" | awk '{print $(NF-4),$(NF-3)}')
    LOSS=$(echo "$LINE" | awk '{print $(NF-1)}')
    JITTER=$(echo "$LINE" | awk '{print $(NF-2)}')
    echo "$BW | 丢包:$LOSS | 抖动:${JITTER}ms"
}

#################################
start_server() {
    if [ -f "$SERVER_PID_FILE" ] && ps -p $(cat "$SERVER_PID_FILE") &>/dev/null; then
        echo -e "${YELLOW}已在运行${RESET}"
        return
    fi

    nohup iperf3 -s -i 10 -p $PORT >/dev/null 2>&1 &
    echo $! > "$SERVER_PID_FILE"

    echo -e "${GREEN}服务端已启动 PID=$(cat $SERVER_PID_FILE)${RESET}"
}

#################################
stop_server() {
    if [ -f "$SERVER_PID_FILE" ]; then
        kill $(cat "$SERVER_PID_FILE") 2>/dev/null
        rm -f "$SERVER_PID_FILE"
        echo -e "${RED}服务端已停止${RESET}"
    else
        echo "未运行"
    fi
    read
}

#################################
run_server() {
    IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
    echo "公网IP: $IP"
    iperf3 -s -i 10 -p $PORT
}

#################################
run_client_tcp() {
    read -p "服务器 IP: " IP
    [ -z "$IP" ] && return

    echo "===== TCP 上传 ====="
    UP=$(iperf3 -c $IP -P 1 -t $TIME -p $PORT)
    UP_RES=$(parse_tcp "$UP")
    echo "上传: $UP_RES"

    echo "===== TCP 下载 ====="
    DOWN=$(iperf3 -c $IP -R -P 1 -t $TIME -p $PORT)
    DOWN_RES=$(parse_tcp "$DOWN")
    echo "下载: $DOWN_RES"

    log_result "TCP 上传:$UP_RES 下载:$DOWN_RES"
    read
}

#################################
run_client_udp() {
    read -p "服务器 IP: " IP
    [ -z "$IP" ] && return

    read -p "带宽(默认 $UDP_BANDWIDTH): " BW
    [ -n "$BW" ] && UDP_BANDWIDTH=$BW

    echo "===== UDP 上传 ====="
    UP=$(iperf3 -c $IP -u -b $UDP_BANDWIDTH -P 1 -t $TIME -p $PORT)
    UP_RES=$(parse_udp "$UP")
    echo "上传: $UP_RES"

    echo "===== UDP 下载 ====="
    DOWN=$(iperf3 -c $IP -u -b $UDP_BANDWIDTH -R -P 1 -t $TIME -p $PORT)
    DOWN_RES=$(parse_udp "$DOWN")
    echo "下载: $DOWN_RES"

    log_result "UDP 上传:$UP_RES 下载:$DOWN_RES"
    read
}

#################################
delete_log() {
    rm -f "$LOGFILE"
    echo "日志已删除"
    read
}

#################################
view_log() {
    tail -f "$LOGFILE"
}

#################################
menu() {
    clear
    echo -e "${GREEN}====== iperf3 双向测速菜单 ======${RESET}"
    echo -e "${GREEN}1) 前台服务端${RESET}"
    echo -e "${GREEN}2) 后台启动服务端${RESET}"
    echo -e "${GREEN}3) 停止后台服务端${RESET}"
    echo -e "${GREEN}4) TCP 双向测速${RESET}"
    echo -e "${GREEN}5) UDP 双向测速(自定义带宽)${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 删除日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
}

#################################
main() {
    init_dir
    install_iperf3

    while true; do
        menu
        read -p "选择: " c
        case $c in
            1) run_server ;;
            2) start_server ;;
            3) stop_server ;;
            4) run_client_tcp ;;
            5) run_client_udp ;;
            6) view_log ;;
            7) delete_log ;;
            0) exit ;;
        esac
    done
}

main
