#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 配置信息 ==================
SCRIPT_PATH="/root/toolt.sh"
SCRIPT_URL="https://raw.githubusercontent.com/Polarisiu/tool/main/toolt.sh"
BIN_LINK="/usr/local/bin/t"
BIN_LINK_UPPER="/usr/local/bin/T"

# 0. 检测是否已安装
# 如果主脚本已存在且可执行，直接运行它并退出当前脚本
if [ -x "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}检测到工具箱已安装，正在为您打开...${RESET}"
    exec "$SCRIPT_PATH"
fi

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ 错误：请以 root 用户运行此脚本！${RESET}"
    exit 1
fi

echo -e "${YELLOW}正在首次安装 VPS 工具箱...${RESET}"

# 2. 下载并覆盖主脚本
curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ 下载失败，请检查网络或 URL${RESET}"
    exit 1
fi

# 3. 授权与软链接
chmod +x "$SCRIPT_PATH"
ln -sf "$SCRIPT_PATH" "$BIN_LINK"
ln -sf "$SCRIPT_PATH" "$BIN_LINK_UPPER"

# 4. 完成安装并立即启动
echo -e "------------------------------------------------"
echo -e "${GREEN}✅ 安装完成！${RESET}"
echo -e "${GREEN}✅ 快捷指令：输入 ${RED}T${RESET}${GREEN} 或 ${RED}t${RESET}${GREEN} 即可运行。${RESET}"
echo -e "------------------------------------------------"

# 自动执行主脚本
exec "$SCRIPT_PATH"
