#!/bin/bash
# ==========================================
# Windows10 LTSC 2021 DD 一键重装脚本
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

IMAGE_URL="https://oss.sunpma.com/Windows/Win10_2021LTSC_64_Administrator_nat.ee.gz"
SCRIPT_URL="https://moeclub.org/attachment/LinuxShell/InstallNET.sh"
SCRIPT_NAME="InstallNET.sh"

echo -e "${YELLOW}"
echo "================================"
echo " Windows10 LTSC 2021 DD 重装工具"
echo "================================"
echo "系统: Windows 10 LTSC 2021"
echo "账号: Administrator"
echo "密码: nat.ee"
echo "远程端口: 3389"
echo "================================"
echo -e "${RESET}"

read -p "确认开始重装？(y/N): " confirm

if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo -e "${RED}已取消操作${RESET}"
    exit 0
fi

echo -e "${GREEN}开始下载重装脚本...${RESET}"

wget --no-check-certificate -O $SCRIPT_NAME $SCRIPT_URL

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败${RESET}"
    exit 1
fi

chmod +x $SCRIPT_NAME

echo -e "${GREEN}开始 DD 安装 Windows...${RESET}"
echo -e "${RED}警告：系统即将被覆盖！${RESET}"

sleep 5

bash $SCRIPT_NAME -dd "$IMAGE_URL"
