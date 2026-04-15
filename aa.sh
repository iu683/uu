#!/bin/bash
# ========================================
# Xray + 3x-ui 彻底卸载脚本
# 支持 apt / yum / 手动安装 / 脚本安装
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}  Xray彻底卸载开始执行${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 停服务
# =============================
echo -e "${YELLOW}[1/6] 停止相关服务...${RESET}"

systemctl stop xray 2>/dev/null
systemctl disable xray 2>/dev/null

systemctl stop xray@* 2>/dev/null
systemctl disable xray@* 2>/dev/null

systemctl stop 3x-ui 2>/dev/null
systemctl disable 3x-ui 2>/dev/null

pkill -9 xray 2>/dev/null

# =============================
# 卸载 3x-ui
# =============================
echo -e "${YELLOW}[2/6] 卸载 3x-ui 面板...${RESET}"

if command -v x-ui &>/dev/null; then
    x-ui uninstall 2>/dev/null
fi

rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -f /usr/local/bin/x-ui
rm -f /etc/systemd/system/3x-ui.service

# =============================
# apt / yum 卸载 Xray
# =============================
echo -e "${YELLOW}[3/6] 检测包管理安装...${RESET}"

if command -v apt &>/dev/null && dpkg -l 2>/dev/null | grep -q xray; then
    apt purge -y xray
    apt autoremove -y
elif command -v yum &>/dev/null && rpm -qa | grep -q xray; then
    yum remove -y xray
fi

# =============================
# 删除核心文件
# =============================
echo -e "${YELLOW}[4/6] 清理残留文件...${RESET}"

rm -f /usr/local/bin/xray
rm -f /usr/bin/xray

rm -rf /etc/xray
rm -rf /usr/local/etc/xray
rm -rf /var/log/xray

rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service

systemctl daemon-reload

# =============================
# Docker 清理（仅相关）
# =============================
echo -e "${YELLOW}[5/6] 清理 Docker 相关容器...${RESET}"

if command -v docker &>/dev/null; then
    docker ps -a --format "{{.Names}}" | grep -Ei 'xray|3x-ui' | xargs -r docker rm -f
fi

# =============================
# 端口检查
# =============================
echo -e "${YELLOW}[6/6] 检查残留端口...${RESET}"

ports=$(ss -tulnp 2>/dev/null | grep -i xray)

if [[ -n "$ports" ]]; then
    echo -e "${RED}仍有占用:${RESET}"
    echo "$ports"
else
    echo -e "${GREEN}无残留端口${RESET}"
fi

# =============================
# 完成
# =============================
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}✅ Xray已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
