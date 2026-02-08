#!/bin/bash
# ======================================
# Ookla Speedtest 一键安装脚本
# Debian / Ubuntu 通用
# ======================================

set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}🚀 开始安装 Speedtest CLI...${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 或 sudo 运行！${RESET}"
  exit 1
fi

# 安装 curl
if ! command -v curl >/dev/null 2>&1; then
  echo "📦 安装 curl..."
  apt-get update -y
  apt-get install -y curl
fi

# 添加 Ookla 官方源
echo "📦 添加 Ookla 仓库..."
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash

# 安装 speedtest
echo "📦 安装 speedtest..."
apt-get install -y speedtest

echo -e "${GREEN}✅ 安装完成！${RESET}"

# 自动测速
echo ""
echo -e "${GREEN}🚀 开始测速...${RESET}"
echo "-------------------------------------"

speedtest --accept-license --accept-gdpr

echo "-------------------------------------"
echo -e "${GREEN}🎉 完成！以后直接运行： speedtest${RESET}"
