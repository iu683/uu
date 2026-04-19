#!/bin/bash

# ========================================
# 颜色定义
# ========================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# ========================================
# Root 检查
# ========================================
[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请使用 root 运行${RESET}" && exit 1

# ========================================
# 系统识别
# ========================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    echo -e "${RED}❌ 无法识别系统类型${RESET}"
    exit 1
fi

echo -e "${GREEN}🚀 开始执行全能系统清理...${RESET}"

# ========================================
# 1. 软件包管理器清理
# ========================================
echo -e "${YELLOW}📦 清理软件包缓存...${RESET}"

case "$OS_ID" in
    debian|ubuntu)
        apt-get autoremove -y
        apt-get autoclean -y
        apt-get clean -y
        # 清理残留的旧内核
        dpkg -l | grep "^rc" | awk '{print $2}' | xargs -r dpkg -P
        ;;
    centos|rhel|rocky|almalinux|fedora)
        yum autoremove -y || dnf autoremove -y
        yum clean all || dnf clean all
        ;;
    alpine)
        apk cache clean
        rm -rf /var/cache/apk/*
        ;;
esac

# ========================================
# 2. 日志文件清理 (保留最近3天)
# ========================================
echo -e "${YELLOW}📜 清理系统日志...${RESET}"

if command -v journalctl >/dev/null 2>&1; then
    # 限制 systemd 日志大小
    journalctl --vacuum-time=3d
    journalctl --vacuum-size=50M
fi

# 清理传统日志文件
find /var/log -type f -name "*.log" -exec truncate -s 0 {} +
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete

# ========================================
# 3. Docker 环境清理 (如果存在)
# ========================================
if command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}🐳 清理 Docker 冗余数据...${RESET}"
    # 清理所有停止的容器、未使用的网络、悬空镜像
    docker system prune -f
    # 如果想更彻底清理未使用的镜像，可以使用 docker image prune -a -f
fi

# ========================================
# 4. 临时文件与缓存清理
# ========================================
echo -e "${YELLOW}🧹 清理临时文件与用户缓存...${RESET}"

# 清理核心转储文件
find / -name "core.[0-9]*" -delete 2>/dev/null || true

# 清理 /tmp 目录 (排除正在使用的)
find /tmp -type f -atime +1 -delete 2>/dev/null || true

# 清理用户级缓存
rm -rf ~/.cache/* 2>/dev/null || true

# ========================================
# 5. 内存释放 (可选)
# ========================================
echo -e "${YELLOW}🧠 释放页面缓存 (Sync & Drop Caches)...${RESET}"
sync && echo 3 > /proc/sys/vm/drop_caches

# ========================================
# 总结输出
# ========================================
echo -e "----------------------------------"
echo -e "${GREEN}✅ 系统清理完成！${RESET}"
echo -e "${YELLOW}当前磁盘使用情况:${RESET}"
df -h / | awk 'NR==1 || NR==2'
echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
