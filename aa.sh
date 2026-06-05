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
    
    # 尝试直连，如果失败（返回非0状态码）则通过代理重试，若再失败则报错退出
    bash <(curl -fsSL "$script_url") || \
    bash <(curl -fsSL "${PROXY}${script_url}") || {
        echo -e "${RED}错误：直连与代理均失败，请检查网络设置。${RESET}"
        exit 1
    }
}

# 安装逻辑判断
case "$OS" in
    alpine)
        # 执行 Alpine 适配版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APAnyRealityS.sh"
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora)
        # 执行原版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/AnyRealityS.sh"
        ;;
    *)  
        # 未能识别或暂不支持您的系统
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/AnyRealityS.sh"
        ;;
esac
