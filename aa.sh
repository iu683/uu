#!/bin/bash
# =========================================
# Linai VPS 安全扫描工具
# 检测挖矿 / 木马 / 后门
# =========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${BLUE}==============================${RESET}"
echo -e "${GREEN}     VPS 安全扫描工具        ${RESET}"
echo -e "${BLUE}==============================${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 运行此脚本！${RESET}"
  exit 1
fi

echo -e "\n${YELLOW}1️⃣ 检查高CPU进程（可能挖矿）${RESET}"
ps aux --sort=-%cpu | head -n 10

echo -e "\n${YELLOW}2️⃣ 检查常见挖矿进程${RESET}"
ps aux | grep -E "xmrig|kdevtmpfsi|kinsing|watchbog|crypto|miner" | grep -v grep

echo -e "\n${YELLOW}3️⃣ 检查可疑端口监听${RESET}"
ss -tulnp | grep -E "3333|4444|5555|6666|7777|14444|9999"

echo -e "\n${YELLOW}4️⃣ 检查异常定时任务${RESET}"
crontab -l 2>/dev/null
ls -al /etc/cron* 2>/dev/null

echo -e "\n${YELLOW}5️⃣ 检查启动项${RESET}"
systemctl list-unit-files --type=service | grep enabled

echo -e "\n${YELLOW}6️⃣ 检查可疑用户（UID=0）${RESET}"
awk -F: '$3 == 0 {print $1}' /etc/passwd

echo -e "\n${YELLOW}7️⃣ 检查可疑网络连接${RESET}"
ss -antp | grep ESTAB | grep -v "127.0.0.1"

echo -e "\n${GREEN}扫描完成 ✔${RESET}"
