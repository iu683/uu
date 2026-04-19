#!/bin/bash

# ========================================
# 颜色定义
# ========================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# Root 检查
[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请使用 root 运行${RESET}" && exit 1

# 系统识别
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    OS_ID="unknown"
fi

echo -e "${GREEN}🚀 开始执行全能系统清理...${RESET}"

# ========================================
# 1. 软件包管理器清理
# ========================================
echo -e "${YELLOW}📦 清理软件包缓存...${RESET}"
case "$OS_ID" in
    debian|ubuntu)
        apt-get autoremove -y >/dev/null 2>&1
        apt-get autoclean -y >/dev/null 2>&1
        apt-get clean -y >/dev/null 2>&1
        dpkg -l | grep "^rc" | awk '{print $2}' | xargs -r dpkg -P >/dev/null 2>&1
        ;;
    centos|rhel|rocky|almalinux|fedora)
        yum autoremove -y >/dev/null 2>&1 || dnf autoremove -y >/dev/null 2>&1
        yum clean all >/dev/null 2>&1 || dnf clean all >/dev/null 2>&1
        ;;
    alpine)
        apk cache clean >/dev/null 2>&1
        rm -rf /var/cache/apk/*
        ;;
esac

# ========================================
# 2. 日志文件清理
# ========================================
echo -e "${YELLOW}📜 清理系统日志...${RESET}"
if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=1d >/dev/null 2>&1
    journalctl --vacuum-size=20M >/dev/null 2>&1
fi

find /var/log -type f -name "*.log" -exec truncate -s 0 {} +
find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete

# ========================================
# 3. Docker 清理
# ========================================
if command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}🐳 清理 Docker 冗余数据...${RESET}"
    docker system prune -f >/dev/null 2>&1
fi

# ========================================
# 4. 临时文件清理
# ========================================
echo -e "${YELLOW}🧹 清理临时文件...${RESET}"
rm -rf /tmp/* 2>/dev/null || true
rm -rf ~/.cache/* 2>/dev/null || true

# ========================================
# 5. 内存释放 (静默权限判定)
# ========================================
echo -e "${YELLOW}🧠 尝试释放页面缓存...${RESET}"
sync
# 检查是否有写入权限，如果有才执行，没有则直接提示
if [ -w /proc/sys/vm/drop_caches ]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${GREEN}✔ 内存释放成功${RESET}"
else
    echo -e "${YELLOW}ℹ️ 当前环境不支持手动释放缓存 (通常见于 LXC/Docker)，已跳过${RESET}"
fi

# ========================================
# 总结输出
# ========================================
echo -e "----------------------------------"
echo -e "${GREEN}✅ 系统清理完成！${RESET}"
echo -e "${YELLOW}当前磁盘使用率:${RESET}"
df -h / | awk 'NR==1 || NR==2'
echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
