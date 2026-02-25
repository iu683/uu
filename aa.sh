#!/bin/bash
# ========================================
# Debian / Ubuntu 一键开启时间同步
# Author: Auto Script
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${BLUE}========================================${RESET}"
echo -e "${GREEN}      ⏰ 一键时间同步配置脚本${RESET}"
echo -e "${BLUE}========================================${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 运行此脚本${RESET}"
    exit 1
fi

# 检测系统
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}❌ 无法识别系统类型${RESET}"
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    echo -e "${RED}❌ 当前系统不是 Debian/Ubuntu${RESET}"
    exit 0
fi

echo -e "${GREEN}✔ 系统检测通过：$PRETTY_NAME${RESET}"

# 安装 systemd-timesyncd
if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
    echo -e "${YELLOW}📦 正在安装 systemd-timesyncd...${RESET}"
    apt update -y
    apt install -y systemd-timesyncd
else
    echo -e "${GREEN}✔ systemd-timesyncd 已安装${RESET}"
fi

# 启用服务
echo -e "${YELLOW}🚀 启动时间同步服务...${RESET}"
systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
systemctl enable --now systemd-timesyncd
timedatectl set-ntp true
systemctl restart systemd-timesyncd

sleep 2

# 状态检查
if systemctl is-active --quiet systemd-timesyncd; then
    echo -e "${GREEN}✔ 时间同步服务已成功启动${RESET}"
else
    echo -e "${RED}❌ 时间同步服务启动失败${RESET}"
    exit 1
fi

echo
echo -e "${BLUE}========== 当前时间状态 ==========${RESET}"
timedatectl status
echo -e "${BLUE}==================================${RESET}"
