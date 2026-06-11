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
    local success=1 # 默认失败状态

    # 遍历代理数组
    for proxy in "${GITHUB_PROXY[@]}"; do
        local full_url="${proxy}${script_url}"
        
        # 提示当前正在尝试的链接
        if [ -z "$proxy" ]; then
            echo
        else
            echo
        fi

        # 执行下载与运行
        if bash <(curl -fsSL --connect-timeout 5 "$full_url"); then
            echo
            success=0
            break # 成功后跳出循环
        fi
    done

    # 如果所有代理都失败了
    if [ $success -ne 0 ]; then
        echo -e "${RED}错误：所有代理通道均已失败，请检查网络连接。${RESET}"
        exit 1
    fi
}

# 安装逻辑判断
case "$OS" in
    alpine)
        # 执行 Alpine 适配版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/APAcme.sh"
        ;;
    debian|ubuntu|centos|rocky|almalinux|fedora|*)
        # 执行原版脚本
        fetch_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/toy/ACMESSL.sh"
        ;;
esac
