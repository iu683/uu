#!/bin/bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

# 自动识别发行版
if [ -f /etc/alpine-release ]; then
    OS="Alpine"
elif grep -qi "ubuntu" /etc/os-release; then
    OS="Ubuntu"
elif [ -f /etc/debian_version ]; then
    OS="Debian"
else
    OS="Linux"
fi

echo -e "${GREEN}=== 字体与语言环境工具 ($OS) ===${RESET}"
echo -e "${GREEN}1) 切换到中文字体${RESET}"
echo -e "${GREEN}2) 切换到英文字体${RESET}"
echo -e "${GREEN}0) 退出${RESET}"
read -rp "$(echo -e ${GREEN}请选择操作: ${RESET})" choice

apply_locale() {
    local target_lang=$1
    
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
        echo -e "${YELLOW}正在更新 apt 并安装字体包...${RESET}"
        apt-get update -y
        if [[ "$target_lang" == "zh_CN.UTF-8" ]]; then
            apt-get install -y locales fonts-wqy-microhei fonts-wqy-zenhei
        else
            apt-get install -y locales fonts-dejavu fonts-liberation
        fi

        # 配置 Locale
        echo -e "${YELLOW}正在生成语言环境: $target_lang...${RESET}"
        sed -i "s/^#\?\s*\($target_lang UTF-8\)/\1/" /etc/locale.gen || echo "$target_lang UTF-8" >> /etc/locale.gen
        locale-gen "$target_lang"
        
        # 强制写入配置
        update-locale LANG="$target_lang" LC_ALL="$target_lang"
        echo "LANG=$target_lang" > /etc/default/locale
        echo "LC_ALL=$target_lang" >> /etc/default/locale
        
    elif [[ "$OS" == "Alpine" ]]; then
        echo -e "${YELLOW}执行 Alpine 深度中文兼容方案...${RESET}"
        
        # 1. 强制安装完整语言支持包
        apk add --no-cache musl-locales musl-locales-lang
        
        # 2. 安装字体
        if [[ "$target_lang" == "zh_CN.UTF-8" ]]; then
            apk add --no-cache ttf-dejavu font-wqy-zenhei --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing
        fi
        
        # 3. 【核心点】Alpine 识别 zh_CN.UTF-8 有时需要写成小写 zh_CN.utf8
        # 我们同时导出两套变量，确保 musl 能识别
        sed -i '/export LANG=/d' /etc/profile
        sed -i '/export LC_ALL=/d' /etc/profile
        
        echo "export LANG=zh_CN.UTF-8" >> /etc/profile
        echo "export LC_ALL=zh_CN.UTF-8" >> /etc/profile
        # 有些 musl 版本只认小写后缀
        echo "export LC_CTYPE=zh_CN.UTF-8" >> /etc/profile
        
        # 4. 立即生效当前 Shell
        export LANG=zh_CN.UTF-8
        export LC_ALL=zh_CN.UTF-8
        export LC_CTYPE=zh_CN.UTF-8
        
        source /etc/profile
    fi

    # 立即对当前 Shell 生效
    export LANG="$target_lang"
    export LC_ALL="$target_lang"
}

case "$choice" in
    1)
        apply_locale "zh_CN.UTF-8"
        echo -e "${GREEN}✅ 中文环境配置完成。${RESET}"
        echo -e "${YELLOW}检测方法：输入 'date' 查看是否显示中文。${RESET}"
        echo -e "${YELLOW}注意：请重新连接 SSH 终端以确保完全生效。${RESET}"
        ;;
    2)
        apply_locale "en_US.UTF-8"
        echo -e "${GREEN}✅ 英文环境配置完成。${RESET}"
        echo -e "${YELLOW}检测方法：输入 'date' 查看是否显示中文。${RESET}"
        echo -e "${YELLOW}注意：请重新连接 SSH 终端以确保完全生效。${RESET}"
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效选择${RESET}"
        exit 1
        ;;
esac
