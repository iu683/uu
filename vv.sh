#!/bin/bash
# ========================================
# Debian 12 一键重装脚本（自动下载 + 执行）
# ========================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${YELLOW}⚠️  警告：该操作会重装系统并清空所有数据！${RESET}"
read -p "是否继续？(y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}已取消操作${RESET}"
    exit 1
fi

echo -e "${GREEN}📥 下载重装脚本...${RESET}"

curl -fsSL -o reinstall.sh https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh \
|| wget -O reinstall.sh https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh

chmod +x reinstall.sh

echo -e "${GREEN}🚀 开始安装 Debian 12...${RESET}"

bash reinstall.sh debian 12

echo -e "${YELLOW}🔄 如果没有自动重启，请手动执行 reboot${RESET}"
