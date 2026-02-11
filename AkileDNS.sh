#!/usr/bin/env bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}=== Akile DNS 优选 ===${RESET}"

#################################
# Root 检测
#################################
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 root 运行此脚本${RESET}"
  exit 1
fi

#################################
# 安装依赖
#################################
echo -e "${YELLOW}▶ 更新软件源...${RESET}"
apt update -y

echo -e "${YELLOW}▶ 安装 curl wget dnsutils(dig)...${RESET}"
apt install -y curl wget dnsutils

#################################
# 下载并运行 akdns
#################################
echo -e "${YELLOW}▶ 下载 Akile DNS 优选脚本...${RESET}"

TMP_SCRIPT="/tmp/akdns.sh"

wget -qO "$TMP_SCRIPT" https://raw.githubusercontent.com/akile-network/aktools/main/akdns.sh

chmod +x "$TMP_SCRIPT"

echo -e "${GREEN}▶ 启动 DNS 优选工具...${RESET}"
bash "$TMP_SCRIPT"
