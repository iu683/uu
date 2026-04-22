#!/bin/bash
clear

# 颜色定义
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
re='\033[0m'

# 1. 设置 root 密码
read -p $'\033[1;35m请设置你的root密码: \033[0m' passwd
echo "root:$passwd" | chpasswd && echo -e "${green}Root密码设置成功${re}" || { echo -e "${red}Root密码修改失败${re}"; exit 1; }

# 2. 修改 sshd_config (使用更稳健的替换逻辑)
SSH_CONF="/etc/ssh/sshd_config"
# 确保权限允许修改
[ -f "$SSH_CONF" ] || { echo -e "${red}错误: 找不到 $SSH_CONF${re}"; exit 1; }

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$SSH_CONF"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$SSH_CONF"
# 针对 Alpine/Debian 的 Include 处理
sed -i 's|^Include /etc/ssh/sshd_config.d/\*.conf|#&|' "$SSH_CONF"

# 3. 重启 SSH 服务 (兼容 OpenRC 和 Systemd)
echo -e "${yellow}正在重载 SSH 配置...${re}"

if [ -f /etc/alpine-release ]; then
    # Alpine Linux 分支 (使用 OpenRC)
    rc-service sshd restart && echo -e "${green}SSH 服务已在 Alpine 上重启${re}"
elif command -v systemctl >/dev/null 2>&1; then
    # Systemd 分支 (Debian/Ubuntu/CentOS)
    if systemctl list-unit-files | grep -q sshd.service; then
        systemctl restart sshd
    elif systemctl list-unit-files | grep -q ssh.service; then
        systemctl restart ssh
    fi
    echo -e "${green}SSH 服务已通过 systemctl 重启${re}"
else
    # 兜底方案 (SysVinit/Old Service)
    service sshd restart || service ssh restart
fi

echo -e "${green}ROOT登录设置完毕，配置已生效${re}"

# 4. 是否重启
read -p $'\033[1;35m需要立即重启服务器吗？(y/n): \033[0m' choice
case "$choice" in
    [Yy]*)
        echo -e "${yellow}正在重启...${re}"
        reboot
        ;;
    *)
        echo -e "${green}已取消重启，配置通常已即时生效，如无法连接请执行 reboot${re}"
        ;;
esac
