#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}检测系统类型...${RESET}"

# 检测是否为 Debian/Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        echo -e "${RED}当前系统不是 Ubuntu 或 Debian，退出。${RESET}"
        exit 1
    fi
else
    echo -e "${RED}无法识别系统类型，退出。${RESET}"
    exit 1
fi

echo -e "${GREEN}系统检测通过：$PRETTY_NAME${RESET}"

# 检查是否已安装
if dpkg -s systemd-timesyncd >/dev/null 2>&1; then
    echo -e "${GREEN}systemd-timesyncd 已安装。${RESET}"
else
    echo -e "${YELLOW}未检测到 systemd-timesyncd，开始安装...${RESET}"
    apt update
    apt install -y systemd-timesyncd
fi

# 启用并启动
echo -e "${YELLOW}启用时间同步服务...${RESET}"
systemctl unmask systemd-timesyncd
systemctl enable --now systemd-timesyncd

# 启用 NTP
timedatectl set-ntp true

echo -e "${GREEN}时间同步服务已启动！${RESET}"
echo
timedatectl status