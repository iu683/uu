#!/bin/bash
# ==========================================
# iperf3 一键测速管理脚本
# 自动安装 + 四分测速菜单
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"
ORANGE='\033[38;5;208m'

PORT=5201
TIME=30
PARALLEL=1
UDP_BW="1G"

# =============================
# 自动检测并安装 iperf3
# =============================
install_iperf3() {
    if command -v iperf3 >/dev/null 2>&1; then
        return
    fi

    echo -e "${YELLOW}未检测到 iperf3，正在自动安装...${RESET}"

    if [ -f /etc/debian_version ]; then
        apt update -y >/dev/null 2>&1
        apt install -y iperf3 >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y iperf3 >/dev/null 2>&1
    else
        echo -e "${RED}不支持的系统，请手动安装 iperf3${RESET}"
        exit 1
    fi

    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "${RED}iperf3 安装失败${RESET}"
        exit 1
    fi
}

# =============================
# 获取服务器 IP
# =============================
get_ip() {
    read -p "请输入服务器 IP: " SERVER_IP
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}未输入 IP${RESET}"
        return 1
    fi
    return 0
}

# =============================
# 启动服务器
# =============================
start_server() {
    install_iperf3
    echo -e "${GREEN}启动 iperf3 服务器 (端口 $PORT)...${RESET}"
    iperf3 -s -i 10 -p $PORT
}

# =============================
# 四种测试
# =============================
tcp_download() {
    install_iperf3
    get_ip || return
    echo -e "\n${GREEN}TCP 下载 (↓) 测试中...${RESET}"
    iperf3 -c $SERVER_IP -R -P $PARALLEL -t $TIME -p $PORT
    read -p "按回车返回菜单..."
}

tcp_upload() {
    install_iperf3
    get_ip || return
    echo -e "\n${GREEN}TCP 上传 (↑) 测试中...${RESET}"
    iperf3 -c $SERVER_IP -P $PARALLEL -t $TIME -p $PORT
    read -p "按回车返回菜单..."
}

udp_download() {
    install_iperf3
    get_ip || return
    echo -e "\n${GREEN}UDP 下载 (↓) 测试中...${RESET}"
    iperf3 -c $SERVER_IP -u -b $UDP_BW -t $TIME -R -P $PARALLEL -p $PORT
    read -p "按回车返回菜单..."
}

udp_upload() {
    install_iperf3
    get_ip || return
    echo -e "\n${GREEN}UDP 上传 (↑) 测试中...${RESET}"
    iperf3 -c $SERVER_IP -u -b $UDP_BW -t $TIME -P $PARALLEL -p $PORT
    read -p "按回车返回菜单..."
}

# =============================
# 主菜单
# =============================
menu() {
    while true; do
        clear
        echo -e "${ORANGE}=====================================${RESET}"
        echo -e "${ORANGE}        iperf3 一键测速管理         ${RESET}"
        echo -e "${ORANGE}=====================================${RESET}"
        echo -e " ${GREEN}1) 启动 iperf3 服务器${RESET}"
        echo -e " ${GREEN}2) TCP 下载 (↓)${RESET}"
        echo -e " ${GREEN}3) TCP 上传 (↑)${RESET}"
        echo -e " ${GREEN}4) UDP 下载 (↓)${RESET}"
        echo -e " ${GREEN}5) UDP 上传 (↑)${RESET}"
        echo -e " ${GREEN}0) 退出${RESET}"
        echo -ne "${GREEN}请选择: ${RESET}"
        read choice

        case "$choice" in
            1) start_server ;;
            2) tcp_download ;;
            3) tcp_upload ;;
            4) udp_download ;;
            5) udp_upload ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

menu
