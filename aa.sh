#!/bin/bash
# ========================================
# 安全版 Debian 重装执行器
# 功能: 下载远程重装脚本，执行前安全确认
# ========================================

BASE_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
SCRIPT_NAME="reinstall.sh"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${GREEN}警告: 此操作将会完全重装系统，磁盘上所有数据将丢失！${RESET}"
echo -e "${GREEN}请确保已备份重要数据！${RESET}"

# 用户确认
read -p $'\033[31m你确定要继续吗？(y/n): \033[0m' CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}已取消操作${RESET}"
    exit 1
fi

# 代理设置（仅用于下载本脚本）
read -p "是否启用 GitHub镜像代理(y/N, 默认直连): " USE_PROXY
if [[ "$USE_PROXY" == "y" || "$USE_PROXY" == "Y" ]]; then
    REINSTALL_URL="https://cnb.cool/${BASE_URL}"
    echo -e "${GREEN}已启用代理下载。${RESET}"
else
    REINSTALL_URL="$BASE_URL"
fi

# 用户名（默认 root）
read -p "请输入用户名 (默认 root): " USERNAME
USERNAME=${USERNAME:-root}

# SSH 公钥输入
read -p "请输入 SSH 登录公钥 (留空则使用密码登录): " SSH_KEY

# 密码输入与随机生成逻辑
ROOT_PASS=""
if [[ -z "$SSH_KEY" ]]; then
    read -p "请输入 ${USERNAME} 密码 (留空则自动生成随机密码): " ROOT_PASS
    if [[ -z "$ROOT_PASS" ]]; then
        # 生成 16 位随机密码（包含大小写字母、数字）
        ROOT_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        echo -e "${YELLOW}==================================================${RESET}"
        echo -e "${YELLOW}🔑 未输入密码，已自动为您生成随机强密码：${RESET}"
        echo -e "${RED}${ROOT_PASS}${RESET}"
        echo -e "${YELLOW}请务必复制并妥善保存此密码！${RESET}"
        echo -e "${YELLOW}==================================================${RESET}"
        read -p "请按 Enter 键确认已保存密码并继续..."
    fi
else
    echo -e "${GREEN}检测到已提供 SSH 公钥，将跳过密码设置。${RESET}"
fi

# SSH 端口
read -p "请输入 SSH 端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# 下载脚本
echo -e "${GREEN}正在下载重装...${RESET}"
if ! wget -q "$REINSTALL_URL" -O "$SCRIPT_NAME"; then
    echo -e "${RED}❌ 下载失败，请检查网络或代理配置。${RESET}"
    exit 1
fi

chmod +x "$SCRIPT_NAME"

# 组装执行参数
CMD=("./$SCRIPT_NAME" "debian" "13" --username "$USERNAME" --ssh-port "$SSH_PORT")

# 根据输入动态添加密码或密钥
if [[ -n "$SSH_KEY" ]]; then
    CMD+=(--ssh-key "$SSH_KEY")
else
    CMD+=(--password "$ROOT_PASS")
fi

# 执行重装脚本
echo -e "${GREEN}🔧 正在执行重装...${RESET}"
"${CMD[@]}"

# 绿色重启提示
echo -e "${GREEN}✔ 系统将在完成后重启。${RESET}"
read -p "按 Enter 确认重启..." dummy

echo -e "${GREEN}>>> 正在重启系统...${RESET}"
reboot
