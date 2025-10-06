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

echo -e "${GREEN}=== VPS 字体切换工具 ===${RESET}"
echo -e "${GREEN}1) 切换到中文字体${RESET}"
echo -e "${GREEN}2) 切换到英文字体${RESET}"
echo -e "${GREEN}0) 退出${RESET}"
read -rp "$(echo -e ${GREEN}请选择操作: ${RESET})" choice

case "$choice" in
    1)
        echo -e "${GREEN}正在设置中文字体环境...${RESET}"
        apt-get update -y
        apt-get install -y locales fonts-wqy-microhei fonts-wqy-zenhei

        # 确保中文 locale 存在
        grep -qxF "zh_CN.UTF-8 UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen zh_CN.UTF-8

        # 更新系统默认 locale
        update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8

        # 写入 /etc/default/locale 并立即生效
        echo "LANG=zh_CN.UTF-8" > /etc/default/locale
        echo "LC_ALL=zh_CN.UTF-8" >> /etc/default/locale
        export LANG=zh_CN.UTF-8
        export LC_ALL=zh_CN.UTF-8
        source /etc/default/locale

        echo -e "${GREEN}✅ 中文字体环境已应用完成${RESET}"
        locale
        ;;
    2)
        echo -e "${GREEN}正在设置英文字体环境...${RESET}"
        apt-get update -y
        apt-get install -y locales fonts-dejavu fonts-liberation fonts-freefont-ttf

        # 确保英文 locale 存在
        grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen en_US.UTF-8

        # 更新系统默认 locale
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

        # 写入 /etc/default/locale 并立即生效
        echo "LANG=en_US.UTF-8" > /etc/default/locale
        echo "LC_ALL=en_US.UTF-8" >> /etc/default/locale
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8
        source /etc/default/locale

        echo -e "${GREEN}✅ 英文字体环境已应用完成${RESET}"
        locale
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效选择${RESET}"
        exit 1
        ;;
esac
