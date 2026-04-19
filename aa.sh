#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ========================================
# 颜色定义
# ========================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# ========================================
# Root 检查与系统识别
# ========================================
[ "$(id -u)" -ne 0 ] && echo -e "${RED}❌ 请用 root 运行${RESET}" && exit 1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    echo -e "${RED}❌ 无法识别系统${RESET}"
    exit 1
fi

# ========================================
# 分支 1: Alpine 极简路径 (执行后直接退出)
# ========================================
if [ "$OS_ID" = "alpine" ]; then
    echo -e "${YELLOW}🚀 Alpine 极简更新...${RESET}"
    apk update && apk upgrade
    apk add --no-cache bash curl wget vim tar sudo git gzip openssl ca-certificates
    echo -e "${GREEN}✅ Alpine 更新完成${RESET}"
    echo -e "${YELLOW}时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
    exit 0
fi

# ========================================
# 工具函数 (针对 Debian/Ubuntu/RHEL)
# ========================================

fix_docker_sources() {
    echo -e "${YELLOW}🔍 检查重复 Docker 源...${RESET}"
    local files
    files=$(grep -rl "download.docker.com" /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ $(echo "$files" | grep -c /) -gt 1 ]; then
        echo "$files" | tail -n +2 | xargs rm -f
        echo -e "${GREEN}✔ 已清理重复源${RESET}"
    fi
}

fix_sources() {
    [ "$OS_ID" != "debian" ] && return
    echo -e "${YELLOW}🔧 修复 Debian 源兼容性...${RESET}"
    files=$(grep -rl "deb" /etc/apt/ 2>/dev/null || true)
    for f in $files; do
        sed -i -r 's/\bnon-free(-firmware){0,3}\b/non-free/g' "$f"
    done
}

install_base() {
    echo -e "${GREEN}📦 安装组件 (Debian/Ubuntu)...${RESET}"
    apt update && apt upgrade -y
    apt install -y curl wget git vim sudo bash gzip tar unzip rsync \
        net-tools lsof iperf3 mtr jq openssl \
        netcat-openbsd bind9-dnsutils cron systemd-timesyncd || true
    systemctl enable --now cron || true
}

install_rhel() {
    echo -e "${GREEN}📦 安装组件 (RHEL/CentOS)...${RESET}"
    pkg_mgr=$(command -v dnf || echo "yum")
    $pkg_mgr upgrade -y
    $pkg_mgr install -y curl wget git vim sudo bash gzip tar unzip rsync \
        net-tools lsof iperf3 mtr jq openssl nc bind-utils cronie
    systemctl enable --now crond || true
}

set_timezone() {
    echo -e "${YELLOW}🌏 配置时区...${RESET}"
    # 尝试自动获取，失败则默认上海
    tz=$(curl -s --max-time 5 ipapi.co/timezone || echo "Asia/Shanghai")
    timedatectl set-timezone "$tz" || timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || true
    echo -e "${GREEN}✔ 时区已设为: $tz${RESET}"
}

enable_bbr() {
    echo -e "${YELLOW}🚀 启用 BBR 加速...${RESET}"
    if modprobe tcp_bbr 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null
        echo -e "${GREEN}✔ BBR 启用成功${RESET}"
    else
        echo -e "${RED}❌ 内核不支持 BBR${RESET}"
    fi
}

install_nexttrace() {
    command -v nexttrace >/dev/null && return
    echo -e "${YELLOW}🌐 安装 NextTrace...${RESET}"
    curl -sL https://nxtrace.org/nt | bash || echo -e "${RED}❌ NextTrace 安装失败${RESET}"
}

# ========================================
# 主逻辑执行
# ========================================
echo -e "${GREEN}🚀 开始系统更新...${RESET}"

if [[ "$OS_ID" =~ debian|ubuntu ]]; then
    fix_docker_sources
    fix_sources
    install_base
elif [[ "$OS_ID" =~ centos|rhel|rocky|almalinux|fedora ]]; then
    install_rhel
fi

set_timezone
install_nexttrace
enable_bbr

# 网络检测
echo -e "${YELLOW}🌍 网络连接测试:${RESET}"
curl -I -s --max-time 5 https://google.com >/dev/null && echo -e "${GREEN}✔ 外网访问正常${RESET}" || echo -e "${RED}❌ 外网访问受阻${RESET}"

echo -e "----------------------------------"
echo -e "${GREEN}✅ 更新任务全部完成！${RESET}"
echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
