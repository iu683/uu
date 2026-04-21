#!/bin/bash

# ===============================
# SSH 一键安全加固
# ===============================

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

SSH_CONF="/etc/ssh/sshd_config"

# 权限检查
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须以 root 权限运行此脚本${RESET}"
   exit 1
fi

echo -e "${YELLOW}开始执行 SSH 一键加固任务...${RESET}"

# 1. 配置密钥登录
echo -e "\n${YELLOW}[1/3] 正在生成密钥对并配置公钥登录...${RESET}"
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 默认生成 Ed25519 密钥
KEY_PATH="/root/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
else
    echo -e "${GREEN}检测到现有密钥，跳过生成步骤${RESET}"
fi

# 将公钥加入信任列表
cat "${KEY_PATH}.pub" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 2. 修改配置 (禁用密码，允许密钥)
echo -e "${YELLOW}[2/3] 正在修改 sshd_config 禁用密码登录...${RESET}"
[ -f "$SSH_CONF" ] && cp "$SSH_CONF" "${SSH_CONF}.bak"

# 确保配置生效
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$SSH_CONF"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/g' "$SSH_CONF"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' "$SSH_CONF"

# 3. 重启 SSH 服务
echo -e "${YELLOW}[3/3] 正在重启 SSH 服务...${RESET}"

if command -v systemctl &>/dev/null; then
    systemctl restart sshd || systemctl restart ssh
elif command -v rc-service &>/dev/null; then
    rc-service sshd restart || rc-service ssh restart
else
    service sshd restart || service ssh restart
fi

echo -e "\n${GREEN}========================================${RESET}"
echo -e "${GREEN}所有操作已完成！${RESET}"
echo -e "请务必${RED}不要立即断开当前连接${RESET}！"
echo -e "请开启一个新终端尝试使用密钥登录。"
echo -e "私钥位置: ${YELLOW}${KEY_PATH}${RESET}"
echo -e "私钥内容: "
cat "${KEY_PATH}"
echo -e "${GREEN}========================================${RESET}"
