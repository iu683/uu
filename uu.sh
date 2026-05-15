#!/bin/bash
# ========================================
# ShellCrash 一键安装脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/juewuy/ShellCrash/master/install.sh"

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}      ShellCrash 开始安装${RESET}"
echo -e "${GREEN}========================================${RESET}"

# 检测 curl
if ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"

    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl
    elif command -v yum &>/dev/null; then
        yum install -y curl
    elif command -v apk &>/dev/null; then
        apk add curl
    else
        echo -e "${RED}无法自动安装 curl，请手动安装${RESET}"
        exit 1
    fi
fi

echo -e "${GREEN}正在下载安装脚本...${RESET}"

if bash -c "$(curl -fsSL $INSTALL_URL)"; then
    source /etc/profile &>/dev/null

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      ShellCrash 安装完成${RESET}"
    echo -e "${GREEN}========================================${RESET}"
else
    echo -e "${RED}========================================${RESET}"
    echo -e "${RED}      ShellCrash 安装失败${RESET}"
    echo -e "${RED}========================================${RESET}"
    exit 1
fi
