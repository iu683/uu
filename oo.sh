#!/bin/bash
# ========================================
# ShellCrash 一键安装脚本
# 自动刷新环境变量
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

clear

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}       ShellCrash 开始安装${RESET}"
echo -e "${GREEN}========================================${RESET}"

# 检查 curl
if ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"

    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl
    elif command -v yum &>/dev/null; then
        yum install -y curl
    elif command -v dnf &>/dev/null; then
        dnf install -y curl
    elif command -v apk &>/dev/null; then
        apk add curl
    else
        echo -e "${RED}无法自动安装 curl，请手动安装${RESET}"
        exit 1
    fi
fi

# 核心下载与执行函数（含自动容灾代理）
fetch_and_run() {
    local script_url="$1"
    
    # 尝试直连，如果失败（返回非0状态码）则通过代理重试，若再失败则报错退出
    bash <(curl -fsSL "$script_url") || \
    bash <(curl -fsSL "${PROXY}${script_url}") || {
        exit 1
    }
}

# 下载并执行安装

fetch_and_run "https://raw.githubusercontent.com/juewuy/ShellCrash/master/install.sh"


echo -e "${YELLOW}如果命令未立即生效，请执行：${RESET}"
echo -e "${YELLOW}source /etc/profile${RESET}"
