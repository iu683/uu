#!/bin/bash
# ========================================
# 安全版 Debian 重装执行器
# 功能: 下载远程重装脚本，执行前安全确认
# ========================================

REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
SCRIPT_NAME="reinstall.sh"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}警告: 此操作将会完全重装系统，磁盘上所有数据将丢失！${RESET}"
echo -e "${GREEN}请确保已备份重要数据！${RESET}"

# 用户确认
read -p $'\033[31m你确定要继续吗？(y/n): \033[0m' CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}已取消操作${RESET}"
    exit 1
fi

# 可见输入密码（不隐藏）
read -p "请输入 root 密码 (用于重装系统): " ROOT_PASS
if [[ -z "$ROOT_PASS" ]]; then
    echo -e "${RED}❌ 密码不能为空，已取消操作。${RESET}"
    exit 1
fi

# SSH 端口
read -p "请输入 SSH 端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# 下载脚本
echo -e "${GREEN}🔄 下载重装脚本...${RESET}"
if ! wget -q "$REINSTALL_URL" -O "$SCRIPT_NAME"; then
    echo -e "${RED}❌ 下载失败，请检查网络或 URL。${RESET}"
    exit 1
fi

chmod +x "$SCRIPT_NAME"
echo -e "${GREEN}✅ 脚本下载完成并赋予执行权限。${RESET}"

# 执行重装脚本
echo -e "${GREEN}🔧 正在执行重装脚本...${RESET}"
./"$SCRIPT_NAME" debian 13 --password "$ROOT_PASS" --ssh-port "$SSH_PORT"

# 绿色重启提示
echo -e "${GREEN}✔ 系统将在完成后重启。${RESET}"
read -p "按 Enter 确认重启..." dummy

echo -e "${GREEN}>>> 正在重启系统...${RESET}"
reboot
