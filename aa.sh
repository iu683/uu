#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查是否 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行此脚本${RESET}"
    exit 1
fi

# -------------------------
# 获取系统 ID
# -------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_CODENAME="$VERSION_CODENAME"
else
    echo -e "${RED}❌ 无法检测系统发行版 (/etc/os-release 不存在)${RESET}"
    exit 1
fi

# ==========================================
# 逻辑分支 1: Alpine Linux (极简安装)
# ==========================================
if [ "$OS_ID" = "alpine" ]; then
    echo -e "${YELLOW}🚀 检测到 Alpine Linux，执行极简初始化...${RESET}"
    apk update && apk upgrade
    apk add --no-cache bash curl wget vim tar sudo git gzip openssl ca-certificates
    echo -e "${GREEN}✅ Alpine 初始化完成！${RESET}"
    exit 0
fi

# ==========================================
# 逻辑分支 2: Debian/Ubuntu/RHEL (完整功能)
# ==========================================

# -------------------------
# 常用辅助函数
# -------------------------

# 修复 Docker 重复源
fix_duplicate_docker_sources() {
    echo -e "${YELLOW}🔍 检查重复 Docker APT 源...${RESET}"
    local docker_sources
    docker_sources=$(grep -rl "download.docker.com" /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ -n "$docker_sources" ] && [ "$(echo "$docker_sources" | wc -l)" -gt 1 ]; then
        for f in $docker_sources; do
            if [[ "$f" == *"archive_uri"* ]]; then
                rm -f "$f"
                echo -e "${GREEN}✔ 删除多余源: $f${RESET}"
            fi
        done
    fi
}

# 修复 Debian sources.list 兼容性
fix_sources_for_version() {
    local version="$1"
    echo -e "${YELLOW}🔍 修复 $version 兼容性...${RESET}"
    local files
    files=$(grep -rl "deb" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    for f in $files; do
        if [[ "$version" == "bullseye" ]]; then
            sed -i -r 's/\bnon-free(-firmware){0,3}\b/non-free/g' "$f"
            sed -i '/deb .*bullseye-backports/s/^/##/' "$f"
        elif [[ "$version" == "bookworm" ]]; then
            sed -i -r 's/\bnon-free non-free\b/non-free/g' "$f"
        fi
    done
}

# 开启 BBR
enable_bbr() {
    echo -e "${YELLOW}🚀 配置 TCP BBR...${RESET}"
    if ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${RED}❌ 内核不支持 BBR${RESET}"
        return 0
    fi
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null
    echo -e "${GREEN}✔ BBR 已开启${RESET}"
}

# -------------------------
# 主更新流程 (非 Alpine)
# -------------------------
echo -e "${GREEN}🔄 开始系统更新和依赖安装...${RESET}"

if [[ "$OS_ID" =~ debian|ubuntu ]]; then
    fix_duplicate_docker_sources
    [ "$OS_ID" = "debian" ] && fix_sources_for_version "$OS_CODENAME"
    
    apt update && apt upgrade -y
    # 安装核心依赖和工具
    apt install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   netcat-openbsd bind9-dnsutils cron systemd-timesyncd vim gzip bash
    
    # 启用服务
    systemctl enable --now cron
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true
    systemctl enable --now systemd-timesyncd

elif [[ "$OS_ID" =~ fedora|centos|rhel|rocky|almalinux ]]; then
    # 适配 RHEL/CentOS
    yum upgrade -y || dnf upgrade -y
    yum install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   nc bind-utils cronie vim gzip bash || \
    dnf install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   nc bind-utils cronie vim gzip bash
    
    systemctl enable --now crond
    timedatectl set-timezone Asia/Shanghai
fi

# 安装 NextTrace
if ! command -v nexttrace >/dev/null 2>&1; then
    echo -e "${YELLOW}🌐 安装 NextTrace...${RESET}"
    curl -sL https://nxtrace.org/nt | bash
fi

# 开启 BBR
enable_bbr

echo -e "---"
echo -e "${GREEN}✅ 系统初始化完成！${RESET}"
echo -e "${YELLOW}当前时间: $(date)${RESET}"
