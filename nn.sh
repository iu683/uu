#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 代理前缀列表（第一个留空代表直连尝试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 获取操作系统 ID
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# 核心下载与执行函数（多代理自动轮询容灾）
fetch_and_run() {
    local script_url="$1"
    local output_name="$2"
    local success=1

    for proxy in "${GITHUB_PROXY[@]}"; do
        local full_url="${proxy}${script_url}"
        
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW}正在尝试直连下载 ${output_name}...${RESET}"
        else
            echo -e "${YELLOW}直连失败，正在尝试通过代理 [ ${proxy} ] 下载 ${output_name}...${RESET}"
        fi

        if wget -O "$output_name" "$full_url" && [ -s "$output_name" ]; then
            echo -e "${GREEN}下载成功，正在执行...${RESET}"
            chmod +x "$output_name"
            bash "./$output_name"
            success=0
            break
        else
            echo -e "${RED}当前通道下载失败，切换下一个...${RESET}"
            rm -f "$output_name"
        fi
    done

    if [ $success -ne 0 ]; then
        echo -e "${RED}错误：所有代理通道均已失败，无法下载 ${output_name}。${RESET}"
        exit 1
    fi
}

# 安装逻辑判断
case "$OS" in
    alpine)
        #echo -e "${GREEN}检测到操作系统为 Alpine Linux，正在执行预安装与部署...${RESET}"
        fetch_and_run "https://raw.githubusercontent.com/duya07/port-traffic-dog/main/alpine-port-traffic-dog-preinstall.sh" "alpine-port-traffic-dog-preinstall.sh"
        fetch_and_run "https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh" "port-traffic-dog.sh"
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora|*)
        #echo -e "${GREEN}检测到操作系统为 ${OS}，正在部署主脚本...${RESET}"
        fetch_and_run "https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh" "port-traffic-dog.sh"
        ;;
esac
