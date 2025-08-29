#!/bin/sh
# ==========================================
# Alpine 修改 SSH 端口脚本
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}当前 SSH 端口: $(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo 22)${RESET}"
echo "------------------------"
read -p "请输入新的 SSH 端口号: " NEW_PORT

# 校验输入
if ! echo "$NEW_PORT" | grep -Eq '^[0-9]+$'; then
    echo -e "${RED}❌ 端口必须是数字${RESET}"
    exit 1
fi

if [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}❌ 端口号范围必须是 1-65535${RESET}"
    exit 1
fi

# 修改 sshd_config
if grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port ${NEW_PORT}/" /etc/ssh/sshd_config
else
    echo "Port ${NEW_PORT}" >> /etc/ssh/sshd_config
fi

# 放行新端口（Alpine 默认用 iptables/nftables，这里简单处理）
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${NEW_PORT}" -j ACCEPT
    echo -e "${GREEN}✅ 已使用 iptables 放行端口 ${NEW_PORT}${RESET}"
elif command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport "${NEW_PORT}" accept
    echo -e "${GREEN}✅ 已使用 nftables 放行端口 ${NEW_PORT}${RESET}"
else
    echo -e "${YELLOW}⚠️ 未检测到防火墙工具，请手动确认端口已放行${RESET}"
fi

# 重启 sshd (Alpine 用 openrc)
rc-service sshd restart

echo -e "${GREEN}✅ SSH 端口已修改为: ${NEW_PORT}${RESET}"
echo -e "${YELLOW}⚠️ 请在新窗口测试 SSH 是否能连接: ssh -p ${NEW_PORT} user@服务器IP${RESET}"
