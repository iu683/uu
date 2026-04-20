#!/bin/bash


# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s)
fi

# 根据系统执行对应的 Emby 反代脚本
case "$OS" in
    "alpine")
        echo -e "${GREEN}检测到 Alpine Linux，正在启动 Alpine 专用脚本...${RESET}"
        bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/EmbyAlpine.sh)
        ;;
    *)
        echo -e "${GREEN}检测到系统为 $OS，正在启动通用版脚本...${RESET}"
        bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Emby.sh)
        ;;
esac
