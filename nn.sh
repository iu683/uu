#!/bin/bash

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# 默认设置为国外
IS_CN=false

# 尝试多接口获取国家代码 (CN)，限时 3 秒防止卡死
COUNTRY=$(curl -s --max-time 3 https://ip.sb/country_code 2>/dev/null || \
          curl -s --max-time 3 https://ipapi.co/country 2>/dev/null || \
          curl -s --max-time 3 http://ip-api.com/json/ | grep -o '"countryCode":"[^"]*' | cut -d'"' -f4)

if [ "$COUNTRY" = "CN" ]; then
    IS_CN=true
fi

# 根据地理位置执行对应的安装命令
if [ "$IS_CN" = true ]; then
    echo -e "${YELLOW}[CN] 检测到当前服务器位于中国大陆，正在使用国内加速源...${RESET}"
    
    # 确保系统安装了 wget
    if ! command -v wget &> /dev/null; then
        if command -v apk &> /dev/null; then apk add wget >/dev/null
        elif command -v apt-get &> /dev/null; then apt-get update && apt-get install -y wget >/dev/null
        elif command -v yum &> /dev/null; then yum install -y wget >/dev/null
        fi
    fi

    # 执行国内加速安装
    wget -N https://gitlab.com/dabao/nodequality-proxy/-/raw/main/nodequality-proxy.sh && bash nodequality-proxy.sh ghproxy
else
    echo -e "${GREEN}[GLOBAL] 检测到海外服务器${RESET}"
    
    # 确保系统安装了 curl
    if ! command -v curl &> /dev/null; then
        if command -v apk &> /dev/null; then apk add curl >/dev/null
        elif command -v apt-get &> /dev/null; then apt-get update && apt-get install -y curl >/dev/null
        elif command -v yum &> /dev/null; then yum install -y curl >/dev/null
        fi
    fi

    # 执行官方安装
    bash <(curl -sL https://run.NodeQuality.com)
fi
