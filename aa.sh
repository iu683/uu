#!/bin/bash
# ========================================
# Sing-box + S-UI 彻底卸载脚本
# 支持 apt / yum / 手动 / 脚本安装
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}   Sing-box彻底卸载开始执行${RESET}"
echo -e "${RED}========================================${RESET}"

# 必须 root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 身份运行此脚本${RESET}"
    exit 1
fi

# =============================
# 1. 停止服务 & 杀进程
# =============================
echo -e "${YELLOW}[1/7] 停止服务与进程...${RESET}"

# Sing-box
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null

# S-UI
systemctl stop s-ui 2>/dev/null
systemctl disable s-ui 2>/dev/null

# 杀进程
pkill -9 sing-box 2>/dev/null
pkill -9 s-ui 2>/dev/null

# =============================
# 2. 卸载 apt / yum 包
# =============================
echo -e "${YELLOW}[2/7] 检测包管理安装...${RESET}"

if command -v apt &>/dev/null && dpkg -l 2>/dev/null | grep -q sing-box; then
    echo -e "${YELLOW}检测到 apt 安装 Sing-box${RESET}"
    apt purge -y sing-box
    apt autoremove -y

elif command -v yum &>/dev/null && rpm -qa | grep -q sing-box; then
    echo -e "${YELLOW}检测到 yum 安装 Sing-box${RESET}"
    yum remove -y sing-box
fi

# =============================
# 3. 删除可执行文件
# =============================
echo -e "${YELLOW}[3/7] 清理可执行文件...${RESET}"

# Sing-box
rm -f /usr/local/bin/sing-box
rm -f /usr/bin/sing-box

# S-UI
rm -f /usr/bin/s-ui

# =============================
# 4. 删除配置 & 数据 & 日志
# =============================
echo -e "${YELLOW}[4/7] 清理配置与日志...${RESET}"

# Sing-box
rm -rf /etc/sing-box
rm -rf /usr/local/etc/sing-box
rm -rf /var/log/sing-box
rm -rf /opt/sing-box

# S-UI
rm -rf /usr/local/s-ui
rm -rf /etc/s-ui
rm -rf /var/log/s-ui

# =============================
# 5. 删除 systemd 服务
# =============================
echo -e "${YELLOW}[5/7] 清理 systemd 服务...${RESET}"

# Sing-box
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/sing-box@.service

# S-UI
rm -f /etc/systemd/system/s-ui.service

systemctl daemon-reload
systemctl reset-failed

# =============================
# 6. Docker 清理
# =============================
echo -e "${YELLOW}[6/7] 清理 Docker 残留...${RESET}"

if command -v docker &>/dev/null; then
    docker ps -a --format "{{.Names}}" | \
    grep -Ei 'sing-box|singbox|s-ui|sui' | \
    xargs -r docker rm -f
fi

# =============================
# 7. 网络接口 & 残留检查
# =============================
echo -e "${YELLOW}[7/7] 检查残留...${RESET}"

# 检查虚拟网卡
ip link show 2>/dev/null | grep -iE 'sing|tun'

# 检查进程
echo -e "${YELLOW}检查进程:${RESET}"
ps -ef | grep -E 'sing-box|s-ui' | grep -v grep

# 检查端口
echo -e "${YELLOW}检查端口:${RESET}"

ports=$(ss -tulnp 2>/dev/null | grep -Ei 'sing-box|s-ui')

if [[ -n "$ports" ]]; then
    echo -e "${RED}仍有端口占用:${RESET}"
    echo "$ports"
else
    echo -e "${GREEN}无端口残留${RESET}"
fi

# =============================
# 完成
# =============================
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}✅ Sing-box 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
