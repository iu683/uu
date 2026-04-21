#!/bin/bash
# ========================================
# 智能时间同步脚本（自动识别容器/物理机）
# 适配：Debian / Ubuntu / Alpine
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${BLUE}========================================${RESET}"
echo -e "${GREEN}      ⏰ 智能时间同步配置脚本${RESET}"
echo -e "${BLUE}========================================${RESET}"

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 运行${RESET}"
    exit 1
fi

# 2. 系统识别
if [ -f /etc/alpine-release ]; then
    OS="Alpine"
elif [ -f /etc/debian_version ]; then
    OS="Debian/Ubuntu"
else
    echo -e "${RED}❌ 暂不支持此系统${RESET}"
    exit 1
fi

echo -e "${GREEN}✔ 系统检测通过：$OS${RESET}"

# 3. 检测虚拟化环境 (容器无需同步)
IS_CONTAINER=false
if [ "$OS" == "Alpine" ]; then
    # Alpine 下简单检测方式
    if [ -f /.dockerenv ] || grep -qi "docker\|lxc" /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
        VIRT_TYPE="Container"
    fi
else
    # Debian/Ubuntu 使用 systemd-detect-virt
    VIRT_TYPE=$(systemd-detect-virt)
    if [[ "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "openvz" || "$VIRT_TYPE" == "docker" ]]; then
        IS_CONTAINER=true
    fi
fi

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${YELLOW}⚠ 检测到容器环境：$VIRT_TYPE${RESET}"
    echo -e "${GREEN}✔ 容器时间由宿主机管理，无需配置时间同步${RESET}"
    date
    exit 0
fi

# 4. 执行同步逻辑
if [ "$OS" == "Alpine" ]; then
    # ================= Alpine 逻辑 =================
    echo -e "${YELLOW}🔄 正在配置 Alpine 时间同步 (Chrony)...${RESET}"
    apk add --no-cache chrony
    
    # 强制同步一次
    rc-update add chronyd default
    rc-service chronyd stop >/dev/null 2>&1 || true
    
    echo -e "${YELLOW}🚀 正在进行首次强制对时...${RESET}"
    chronyd -q 'server ntp.aliyun.com iburst' || true
    
    rc-service chronyd start
    echo -e "${GREEN}✔ Chrony 服务已启动${RESET}"
    date

else
    # ================= Debian/Ubuntu 逻辑 =================
    echo -e "${YELLOW}🔄 检查并关闭冲突的 NTP 服务...${RESET}"
    systemctl stop ntp chrony 2>/dev/null || true
    systemctl disable ntp chrony 2>/dev/null || true

    if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
        echo -e "${YELLOW}📦 安装 systemd-timesyncd...${RESET}"
        apt update -y && apt install -y systemd-timesyncd
    fi

    echo -e "${YELLOW}🚀 启动时间同步服务...${RESET}"
    systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp false
    sleep 1
    timedatectl set-ntp true
    systemctl restart systemd-timesyncd

    sleep 2
    if systemctl is-active --quiet systemd-timesyncd; then
        echo -e "${GREEN}✔ 时间同步已成功启动${RESET}"
    else
        echo -e "${RED}❌ 启动失败，请检查日志${RESET}"
    fi
    echo -e "${BLUE}========== 当前状态 ==========${RESET}"
    timedatectl status
fi

echo -e "${BLUE}==================================${RESET}"
