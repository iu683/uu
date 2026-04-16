#!/bin/bash
# ========================================
# BBR 一键卸载 & 恢复系统默认 TCP
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}开始恢复系统默认 TCP 拥塞控制...${RESET}"

# =============================
# 1. 恢复 sysctl 默认配置
# =============================
SYSCTL_FILE="/etc/sysctl.conf"
SYSCTL_DIR="/etc/sysctl.d"

# 删除常见 BBR / TCP 优化项
sed -i '/bbr/d' $SYSCTL_FILE 2>/dev/null
sed -i '/tcp_congestion_control/d' $SYSCTL_FILE 2>/dev/null
sed -i '/fq/d' $SYSCTL_FILE 2>/dev/null
sed -i '/net.core.default_qdisc/d' $SYSCTL_FILE 2>/dev/null

rm -f $SYSCTL_DIR/*bbr*.conf 2>/dev/null

# =============================
# 2. 恢复默认 TCP 拥塞控制
# =============================
sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1

# =============================
# 3. 写入默认配置（防止重启又回来）
# =============================
cat > /etc/sysctl.d/99-default-tcp.conf <<EOF
net.ipv4.tcp_congestion_control=cubic
net.core.default_qdisc=pfifo_fast
EOF

sysctl -p >/dev/null 2>&1

# =============================
# 4. 检查当前状态
# =============================
echo ""
echo -e "${GREEN}当前 TCP 状态：${RESET}"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc

# =============================
# 5. 提示
# =============================
echo ""
echo -e "${GREEN}✔ BBR 已卸载 / 已恢复系统默认TCP${RESET}"
echo -e "${YELLOW}如需完全确认，可重启系统${RESET}"
