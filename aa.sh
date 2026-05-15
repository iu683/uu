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

# 下载并执行安装

bash -c "$(curl -fsSL https://raw.githubusercontent.com/juewuy/ShellCrash/master/install.sh)"



echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}       ShellCrash 安装完成${RESET}"
echo -e "${GREEN}========================================${RESET}"

echo -e "${YELLOW}如果命令未立即生效，请执行：${RESET}"
echo -e "source /etc/profile"
