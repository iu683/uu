#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
red="\033[31m"
yellow="\033[33m"
skyblue="\033[36m"
re="\033[0m"

# ================== 工具函数 ==================
random_port() {
    shuf -i 2000-65000 -n 1
}

check_port() {
    local port=$1
    while [[ -n $(lsof -i :$port 2>/dev/null) ]]; do
        echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
        read -p "请输入端口（直接回车使用随机端口）: " port
        [[ -z $port ]] && port=$(random_port) && echo -e "${green}使用随机端口: $port${re}"
    done
    echo $port
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

# ================== 主菜单 ==================
while true; do
    clear
    echo -e "${green}==== MTProto 管理菜单 ====${re}"
    echo -e "${green}1. 安装 MTProto${re}"
    echo -e "${green}2. 卸载 MTProto${re}"
    echo -e "${green}0. 退出${re}"
    read -p "$(echo -e ${green}请选择:${re}) " choice

    case $choice in
        1)
            clear
            install_lsof

            read -p $'\033[1;35m请输入MTProto代理端口(直接回车使用随机端口): \033[0m' port
            [[ -z $port ]] && port=$(random_port) && echo -e "${green}使用随机端口: $port${re}"
            port=$(check_port $port)

            PORT=$port bash <(curl -Ls https://raw.githubusercontent.com/iu683/uu/main/PROXY/aa.sh)
            echo -e "${green}MTProto 安装完成！端口: $port${re}"
            echo
            read -p "按回车返回菜单..."
            ;;
        2)
            clear
            rm -rf mtp && pkill mtg
            echo -e "${red}MTProto 已卸载${re}"
            read -p "按回车返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${red}无效输入！${re}"
            sleep 1
            ;;
    esac
done
