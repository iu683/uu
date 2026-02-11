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
# 依赖检测函数（只首次安装）
#################################
need_install=false

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || need_install=true
}

check_cmd curl
check_cmd wget
check_cmd dig

if $need_install; then
  echo -e "${YELLOW}▶ 首次运行，安装依赖中...${RESET}"
  apt update -y
  apt install -y curl wget dnsutils
else
  echo -e "${GREEN}✔ 依赖已存在，跳过安装${RESET}"
fi

#################################
# 下载并运行 akdns
#################################
echo -e "${YELLOW}▶ 下载 Akile DNS 优选脚本...${RESET}"

TMP_SCRIPT="/tmp/akdns.sh"

wget -qO "$TMP_SCRIPT" https://raw.githubusercontent.com/akile-network/aktools/main/akdns.sh"
chmod +x "$TMP_SCRIPT"

echo -e "${GREEN}▶ 启动 DNS 优选工具...${RESET}"
bash "$TMP_SCRIPT"
