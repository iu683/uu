#!/bin/bash
# iperf3 VPS 双端测速管理菜单 (统一目录版)
# 功能:
# 1) TCP 测速 (最大可用带宽)
# 2) UDP 测速 (丢包率/延迟/抖动)
# 3) 删除日志
# 4) 启动/停止后台服务端
# 5) 查看实时日志
# 自动保存结果到日志，并给出解释

APP_DIR="/opt/iperf3"
LOGFILE="$APP_DIR/iperf3_results.log"
SERVER_PID_FILE="$APP_DIR/iperf3_server.pid"

PORT=5201
TIME=30
PARALLEL=4
UDP_BANDWIDTH="100M"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 初始化目录
init_dir() {
    sudo mkdir -p "$APP_DIR"
    sudo chown -R $(id -u):$(id -g) "$APP_DIR"
}

# 检查/安装 iperf3
install_iperf3() {
    if ! command -v iperf3 &>/dev/null; then
        echo "正在安装 iperf3..."
        if [ -f /etc/debian_version ]; then
            sudo apt update && sudo apt install -y iperf3
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y iperf3
        else
            echo "❌ 无法自动安装 iperf3，请手动安装"
            exit 1
        fi
    fi
}

log_result() {
    echo -e "\n===============================" >> $LOGFILE
    echo "📅 测试时间: $(date '+%Y-%m-%d %H:%M:%S')" >> $LOGFILE
    echo "🔧 模式: $1" >> $LOGFILE
    echo "===============================" >> $LOGFILE
    echo "$2" >> $LOGFILE
    echo -e "===============================\n" >> $LOGFILE
}

interpret_tcp() {
    BANDWIDTH=$(echo "$1" | grep -E "receiver" | tail -n1 | awk '{print $(NF-1), $NF}')
    echo -e "📊 TCP 结果: $BANDWIDTH"
    log_result "TCP" "$1"
    echo ""
    echo "💡 解释:"
    echo "- 这是你链路的最大可用带宽"
    echo "- 如果接近 VPS 带宽上限，说明链路健康"
    echo "- 如果远低于标称带宽，可能是延迟大或丢包导致"
}

interpret_udp() {
    LINE=$(echo "$1" | grep -A1 "receiver" | tail -n1)
    BANDWIDTH=$(echo "$LINE" | awk '{print $(NF-4), $(NF-3)}')
    LOSS=$(echo "$LINE" | awk '{print $(NF-1)}')
    JITTER=$(echo "$LINE" | awk '{print $(NF-2)}')
    echo -e "📊 UDP 结果: $BANDWIDTH, 丢包率 $LOSS, 平均抖动 $JITTER ms"
    log_result "UDP" "$1"
    echo ""
    echo "💡 解释:"
    if [[ "$LOSS" == "0.000%" ]]; then
        echo "- 丢包率几乎为 0，链路很稳定"
    else
        echo "- 丢包率较高，说明网络质量不好，跑大流量可能掉速"
    fi
    echo "- 平均抖动: $JITTER ms"
    echo "- UDP 模式主要看丢包和延迟，不代表真实下载速度"
}

# 服务端后台启动
start_server() {
    if [ -f "$SERVER_PID_FILE" ]; then
        PID=$(cat $SERVER_PID_FILE)
        if ps -p $PID &>/dev/null; then
            echo -e "${YELLOW}ℹ️ 服务端已经在运行 (PID=$PID)${RESET}"
            read -p "是否要先停止它？(y/N): " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                stop_server
            else
                return
            fi
        fi
    fi
    nohup iperf3 -s -p $PORT >/dev/null 2>&1 &
    echo $! > $SERVER_PID_FILE
    echo -e "${GREEN}✅ iperf3 服务端已后台启动，PID=$(cat $SERVER_PID_FILE)${RESET}"
}

stop_server() {
    if [ -f "$SERVER_PID_FILE" ]; then
        PID=$(cat $SERVER_PID_FILE)
        if ps -p $PID &>/dev/null; then
            kill -9 $PID
            echo -e "${RED}✅ 服务端已停止 (PID=$PID)${RESET}"
        else
            echo -e "${YELLOW}ℹ️ 没有找到运行中的服务端${RESET}"
        fi
        rm -f $SERVER_PID_FILE
    else
        echo -e "${YELLOW}ℹ️ 没有找到运行中的服务端${RESET}"
    fi
    read -p "按回车键返回菜单..."
}

# 前台服务端
run_server() {
    echo "🚀 启动 iperf3 服务端，监听端口 $PORT ..."
    echo "👉 你的公网 IP 是: $(curl -s ifconfig.me || curl -s ipinfo.io/ip)"
    echo "👉 请在另一台 VPS 上选择 TCP 或 UDP 输入此 IP"
    iperf3 -s -p $PORT
}

# TCP 客户端
run_client_tcp() {
    read -p "请输入 VPS A 的公网 IP: " SERVER_IP
    [ -z "$SERVER_IP" ] && { echo "❌ 不能为空"; return; }
    echo "⏱ 测试时间: $TIME 秒, 并行流数: $PARALLEL"
    echo "🚀 开始 TCP 测速 (目标 $SERVER_IP)"
    RESULT=$(iperf3 -c $SERVER_IP -p $PORT -t $TIME -P $PARALLEL)
    echo "$RESULT"
    interpret_tcp "$RESULT"
    echo -e "✅ 结果已保存到 $LOGFILE"
    read -p "按回车键返回菜单..."
}

# UDP 客户端
run_client_udp() {
    read -p "请输入 VPS A 的公网 IP: " SERVER_IP
    [ -z "$SERVER_IP" ] && { echo "❌ 不能为空"; return; }
    read -p "请输入测试带宽 (默认 $UDP_BANDWIDTH): " BW
    [ -n "$BW" ] && UDP_BANDWIDTH=$BW
    echo "⏱ 测试时间: $TIME 秒"
    echo "🚀 开始 UDP 测速 (目标 $SERVER_IP, 带宽 $UDP_BANDWIDTH)"
    RESULT=$(iperf3 -c $SERVER_IP -p $PORT -u -b $UDP_BANDWIDTH -t $TIME)
    echo "$RESULT"
    interpret_udp "$RESULT"
    echo -e "✅ 结果已保存到 $LOGFILE"
    read -p "按回车键返回菜单..."
}

# 删除日志
delete_log() {
    if [ -f "$LOGFILE" ]; then
        read -p "⚠️ 确认要删除日志 $LOGFILE 吗？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$LOGFILE"
            echo -e "${GREEN}✅ 日志已删除${RESET}"
        else
            echo -e "${YELLOW}❌ 已取消${RESET}"
        fi
    else
        echo -e "${YELLOW}ℹ️ 日志文件不存在${RESET}"
    fi
    read -p "按回车键返回菜单..."
}

# 查看实时日志
view_log() {
    if [ -f "$LOGFILE" ]; then
        echo -e "${YELLOW}📄 实时查看日志，按 Ctrl+C 退出${RESET}"
        tail -f "$LOGFILE"
    else
        echo -e "${YELLOW}ℹ️ 日志文件不存在${RESET}"
        read -p "按回车键返回菜单..."
    fi
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}=====🚀 iperf3 VPS 双端测速菜单=====${RESET}"
    echo -e "${GREEN}1) 在 VPS A 上运行服务端 (前台)${RESET}"
    echo -e "${GREEN}2) 启动后台服务端${RESET}"
    echo -e "${GREEN}3) 停止后台服务端${RESET}"
    echo -e "${GREEN}4) 在 VPS B 上运行客户端 (TCP)${RESET}"
    echo -e "${GREEN}5) 在 VPS B 上运行客户端 (UDP)${RESET}"
    echo -e "${GREEN}6) 删除日志文件${RESET}"
    echo -e "${GREEN}7) 查看实时日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"
}

main() {
    init_dir
    install_iperf3
    while true; do
        show_menu
        read -p "请选择操作: " choice
        case $choice in
            1) run_server ;;
            2) start_server ;;
            3) stop_server ;;
            4) run_client_tcp ;;
            5) run_client_udp ;;
            6) delete_log ;;
            7) view_log ;;
            0) exit 0 ;;
            *) echo "❌ 无效选择，请重新输入" ; read -p "按回车键返回菜单..." ;;
        esac
    done
}

main
