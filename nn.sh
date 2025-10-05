#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

echo -e "${GREEN}=== VPS 字体环境切换工具 ===${RESET}"
echo -e "${GREEN}1) 切换到中文字体环境 (zh_CN.UTF-8)${RESET}"
echo -e "${GREEN}2) 切换到英文字体环境 (en_US.UTF-8)${RESET}"
echo -e "${GREEN}0) 退出${RESET}"
read -rp "请选择操作[0-2]: " choice

case "$choice" in
    1)
        echo -e "${GREEN}正在设置中文字体环境...${RESET}"
        apt-get update -y
        apt-get install -y locales fonts-wqy-microhei fonts-wqy-zenhei
        grep -qxF "zh_CN.UTF-8 UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8
        export LANG=zh_CN.UTF-8
        export LC_ALL=zh_CN.UTF-8
        source /etc/default/locale
        echo -e "${GREEN}✅ 中文字体环境已应用完成${RESET}"
        ;;
    2)
        echo -e "${GREEN}正在设置英文字体环境...${RESET}"
        apt-get update -y
        apt-get install -y locales fonts-dejavu fonts-liberation fonts-freefont-ttf fonts-ubuntu
        grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8
        source /etc/default/locale
        echo -e "${GREEN}✅ 英文字体环境已应用完成${RESET}"
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效的选项${RESET}"
        exit 1
        ;;
esac
