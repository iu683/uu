#!/bin/bash

# ===============================
# SSH 管理菜单
# ===============================

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

SSH_CONF="/etc/ssh/sshd_config"

# 判断是否为 Alpine 系统
IS_ALPINE=false
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=true
fi

# ===============================
# 函数：配置密钥登录
# ===============================
setup_ssh_key() {
    echo -e "${YELLOW}Step 1: 生成 SSH 密钥并配置公钥登录${RESET}"
    
    # Alpine 独立处理：安装 openssh 工具
    if [ "$IS_ALPINE" = true ]; then
        apk add --no-cache openssh-client openssh-server >/dev/null 2>&1
    fi

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    read -p "请输入密钥保存路径（默认 /root/.ssh/id_ed25519）: " keypath
    keypath=${keypath:-/root/.ssh/id_ed25519}

    ssh-keygen -t ed25519 -f "$keypath"

    cat "${keypath}.pub" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$SSH_CONF"

    echo -e "${GREEN}密钥登录配置完成${RESET}"
    echo "公钥路径: ${keypath}.pub"
    echo "私钥路径: ${keypath}"
    echo -e "\n${GREEN}================== Key ==================${RESET}"
    cat "$keypath"
    echo -e "${GREEN}===========================================${RESET}"
}

# ===============================
# 函数：禁用 root 密码登录
# ===============================
disable_root_password() {
    echo -e "${YELLOW}Step 2: 禁用 root 密码登录${RESET}"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/g' "$SSH_CONF"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' "$SSH_CONF"

    echo -e "${GREEN}root 密码登录已禁用${RESET}"
}

# ===============================
# 函数：重启 SSH 服务
# ===============================
restart_ssh() {
    echo -e "${YELLOW}Step 3: 重启 SSH 服务...${RESET}"

    # Alpine 独立判断执行
    if [ "$IS_ALPINE" = true ]; then
        rc-service sshd restart
    else
        # Ubuntu/Debian 逻辑
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart
    fi

    echo -e "${GREEN}SSH 服务已重启，操作完成！${RESET}"
}

# ===============================
# 菜单循环
# ===============================
while true; do
    echo -e "${GREEN}==== SSH 管理菜单 ====${RESET}"
    echo -e "${GREEN}1) 配置SSH密钥登录${RESET}"
    echo -e "${GREEN}2) 禁用root密码登录${RESET}"
    echo -e "${GREEN}3) 重启SSH服务${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择操作:${RESET}) " choice

    case $choice in
        1) setup_ssh_key ;;
        2) disable_root_password ;;
        3) restart_ssh ;;
        0) break ;;
        *) echo -e "${RED}无效选择，请重新输入${RESET}" ;;
    esac
done
