#!/bin/bash
# ========================================
# Sing-box 彻底卸载脚本
# 支持 apt / yum / 手动 / 脚本安装
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}     Sing-box 彻底卸载开始执行${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停服务 & 杀进程
# =============================
echo -e "${YELLOW}[1/6] 停止 Sing-box 服务...${RESET}"

systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null

pkill -9 sing-box 2>/dev/null

# =============================
# 2. 卸载 apt / yum 包
# =============================
echo -e "${YELLOW}[2/6] 检测包管理安装...${RESET}"

if command -v apt &>/dev/null && dpkg -l 2>/dev/null | grep -q sing-box; then
    echo -e "${YELLOW}检测到 apt 安装 Sing-box${RESET}"
    apt purge -y sing-box
    apt autoremove -y

elif command -v yum &>/dev/null && rpm -qa | grep -q sing-box; then
    echo -e "${YELLOW}检测到 yum 安装 Sing-box${RESET}"
    yum remove -y sing-box
fi

# =============================
# 3. 删除二进制文件
# =============================
echo -e "${YELLOW}[3/6] 清理可执行文件...${RESET}"

rm -f /usr/local/bin/sing-box
rm -f /usr/bin/sing-box

# =============================
# 4. 删除配置 & 日志
# =============================
echo -e "${YELLOW}[4/6] 清理配置与日志...${RESET}"

rm -rf /etc/sing-box
rm -rf /usr/local/etc/sing-box
rm -rf /var/log/sing-box
rm -rf /opt/sing-box

# =============================
# 5. 删除 systemd 服务
# =============================
echo -e "${YELLOW}[5/6] 清理 systemd 服务...${RESET}"

rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/sing-box@.service

systemctl daemon-reload

# =============================
# 6. Docker 清理 + 网络残留
# =============================
echo -e "${YELLOW}[6/6] 清理 Docker 与网络残留...${RESET}"

if command -v docker &>/dev/null; then
    docker ps -a --format "{{.Names}}" | grep -Ei 'sing-box|singbox' | xargs -r docker rm -f
fi

# 清理可能残留的 TUN / 网络接口（防止虚拟网卡残留）
ip link show 2>/dev/null | grep -i sing-box && {
    echo -e "${YELLOW}检测到网络接口残留（可能需手动清理）${RESET}"
}

# =============================
# 最终检查
# =============================
echo -e "${YELLOW}检查残留进程/端口...${RESET}"

ps -ef | grep sing-box | grep -v grep

ports=$(ss -tulnp 2>/dev/null | grep -i sing-box)

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
