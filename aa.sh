#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 代理前缀
PROXY="https://v6.gh-proxy.org/"

# 获取操作系统 ID
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# 核心下载与执行函数（含自动容灾代理）
fetch_and_run() {
    local script_url="$1"
    
    # 尝试直连运行
    if bash <(curl -fsSL "$script_url"); then
    else
        # 拼接代理地址并重试
        if bash <(curl -fsSL "${PROXY}${script_url}"); then
        else
            echo -e "${RED}错误,请检查网络设置。${RESET}"
            exit 1
        fi
    fi
}

# 安装逻辑判断
case "$OS" in
    alpine)
        # 执行 Alpine 适配版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APNginx.sh"
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora)
        # 执行原版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/ngixv4.sh"
        ;;
    *)  
        # 未能识别或暂不支持您的系统
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/ngixv4.sh"
        ;;
esac
