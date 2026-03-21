#!/bin/bash

# ========= 配置 =========
SCRIPT_PATH="/usr/local/bin/byd"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/vv.sh"

# ========= 颜色 =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# ========= root 检测 =========
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行${RESET}"
    exit 1
fi

echo -e "${YELLOW}正在安装代理工具箱...${RESET}"

# 下载主脚本
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ 下载失败，请检查网络或地址${RESET}"
    exit 1
fi

# 赋权
chmod +x "$SCRIPT_PATH"

echo -e "${GREEN}✅ 安装完成！${RESET}"
echo -e "${GREEN}👉 输入 byd 即可启动${RESET}"

# 直接启动
sleep 1
exec "$SCRIPT_PATH"
