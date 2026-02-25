#!/bin/bash
# ========================================
# 智能时间同步脚本（自动识别容器）
# Debian / Ubuntu 专用
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${BLUE}========================================${RESET}"
echo -e "${GREEN}      ⏰ 智能时间同步配置脚本${RESET}"
echo -e "${BLUE}========================================${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 运行${RESET}"
    exit 1
fi

# 检测系统
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}❌ 无法识别系统类型${RESET}"
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    echo -e "${RED}❌ 当前系统不是 Debian/Ubuntu${RESET}"
    exit 0
fi

echo -e "${GREEN}✔ 系统检测通过：$PRETTY_NAME${RESET}"

# ===============================
# 检测虚拟化环境
# ===============================
VIRT_TYPE=$(systemd-detect-virt)

if [[ "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "openvz" || "$VIRT_TYPE" == "docker" ]]; then
    echo -e "${YELLOW}⚠ 检测到容器环境：$VIRT_TYPE${RESET}"
    echo -e "${GREEN}✔ 容器时间由宿主机管理，无需配置时间同步${RESET}"
    echo
    timedatectl status 2>/dev/null || date
    exit 0
fi

echo -e "${GREEN}✔ 物理机 / KVM 环境，开始配置时间同步${RESET}"

# ===============================
# 停止冲突服务
# ===============================
echo -e "${YELLOW}🔄 检查并关闭冲突的 NTP 服务...${RESET}"

systemctl stop ntp 2>/dev/null
systemctl disable ntp 2>/dev/null

systemctl stop chrony 2>/dev/null
systemctl disable chrony 2>/dev/null

# ===============================
# 安装 systemd-timesyncd
# ===============================
if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
    echo -e "${YELLOW}📦 安装 systemd-timesyncd...${RESET}"
    apt update -y
    apt install -y systemd-timesyncd
else
    echo -e "${GREEN}✔ systemd-timesyncd 已安装${RESET}"
fi

# ===============================
# 启用时间同步
# ===============================
echo -e "${YELLOW}🚀 启动时间同步服务...${RESET}"

systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
timedatectl set-ntp false
sleep 1
timedatectl set-ntp true
systemctl restart systemd-timesyncd

sleep 2

# ===============================
# 状态检查
# ===============================
if systemctl is-active --quiet systemd-timesyncd; then
    echo -e "${GREEN}✔ 时间同步已成功启动${RESET}"
else
    echo -e "${RED}❌ 时间同步启动失败，请检查日志${RESET}"
fi

echo
echo -e "${BLUE}========== 当前时间状态 ==========${RESET}"
timedatectl status
echo -e "${BLUE}==================================${RESET}"
