#!/bin/sh
# ========================================
# Xray + 3x-ui 彻底卸载脚本（全平台通用版）
# 支持：Ubuntu / Debian / CentOS / Alpine Linux
# 兼容：systemd / openrc / apt / yum / apk / docker
# 强化：加入对 vless 相关独立进程的保底清理
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}    Xray + 3X-UI 彻底卸载开始执行        ${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止相关服务 (同时兼容 systemd 和 openrc)
# =============================
echo -e "${YELLOW}[1/6] 停止相关服务...${RESET}"

# 1.1 适配 systemd (Ubuntu, Debian, CentOS 等)
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    systemctl stop xray@* >/dev/null 2>&1
    systemctl disable xray@* >/dev/null 2>&1
    systemctl stop 3x-ui >/dev/null 2>&1
    systemctl disable 3x-ui >/dev/null 2>&1
fi

# 1.2 适配 Alpine 的 openrc
if command -v rc-service >/dev/null 2>&1; then
    for service in xray 3x-ui x-ui vless; do
        rc-service $service stop >/dev/null 2>&1
        rc-update del $service default >/dev/null 2>&1
        rm -f /etc/init.d/$service
    done
fi

# 1.3 暴力保底杀进程 (加入了 vless 特征追杀)
if command -v pkill >/dev/null 2>&1; then
    pkill -9 -f xray >/dev/null 2>&1
    pkill -9 -f x-ui >/dev/null 2>&1
    pkill -9 -f vless >/dev/null 2>&1
else
    killall -9 xray >/dev/null 2>&1
    killall -9 x-ui >/dev/null 2>&1
    killall -9 vless >/dev/null 2>&1
fi

# =============================
# 2. 卸载 3x-ui / x-ui 面板
# =============================
echo -e "${YELLOW}[2/6] 检测卸载 3x-ui 面板...${RESET}"

if command -v x-ui >/dev/null 2>&1; then
    x-ui uninstall >/dev/null 2>&1
fi

rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -f /usr/local/bin/x-ui
rm -f /etc/systemd/system/3x-ui.service

# =============================
# 3. 包管理器卸载 Xray
# =============================
echo -e "${YELLOW}[3/6] 检测包管理安装...${RESET}"

if command -v apk >/dev/null 2>&1; then
    # Alpine 环境
    apk del xray >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
    # Debian/Ubuntu 环境
    if dpkg -l 2>/dev/null | grep -q xray; then
        apt purge -y xray
        apt autoremove -y
    fi
elif command -v yum >/dev/null 2>&1; then
    # CentOS/RHEL 环境
    if rpm -qa | grep -q xray; then
        yum remove -y xray
    fi
fi

# =============================
# 4. 删除核心残留文件
# =============================
echo -e "${YELLOW}[4/6] 清理残留文件...${RESET}"

rm -f /usr/local/bin/xray /usr/bin/xray
rm -f /usr/local/bin/vless /usr/bin/vless

rm -rf /etc/xray /usr/local/etc/xray /var/log/xray
rm -rf /etc/vless /usr/local/etc/vless

rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -f /etc/systemd/system/vless.service

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1
fi

# =============================
# 5. Docker 清理 (增加了 vless 镜像与容器筛选)
# =============================
echo -e "${YELLOW}[5/6] 清理 Docker 相关容器...${RESET}"

if command -v docker >/dev/null 2>&1; then
    docker ps -a --format "{{.Names}}" | grep -Ei 'xray|3x-ui|x-ui|vless' | xargs -r docker rm -f >/dev/null 2>&1
fi

# =============================
# 6. 残留审计 (端口与进程检查)
# =============================
echo -e "${YELLOW}[6/6] 检查残留进程与端口...${RESET}"

# 6.1 检查进程 (兼容 BusyBox 格式，增加了 vless)
echo -e "${YELLOW}检查活跃进程...${RESET}"
ps w | grep -Ei 'xray|3x-ui|x-ui|vless' | grep -v grep

# 6.2 检查端口 (兼容 BusyBox ss 或者是 netstat 兜底)
if command -v ss >/dev/null 2>&1; then
    ports=$(ss -tuln 2>/dev/null | grep -Ei 'xray|3x-ui|x-ui|vless')
else
    ports=$(netstat -tuln 2>/dev/null | grep -Ei 'xray|3x-ui|x-ui|vless')
fi

# 使用标准 POSIX [ -n ] 替代 [[ -n ]]
if [ -n "$ports" ]; then
    echo -e "${RED}仍有占用或残留关联端口:${RESET}"
    echo "$ports"
else
    echo -e "${GREEN}无相关残留端口占用${RESET}"
fi

# =============================
# 完成
# =============================
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}  ✅ Xray + 3X-UI + VLESS 已彻底卸载完成  ${RESET}"
echo -e "${GREEN}========================================${RESET}"
