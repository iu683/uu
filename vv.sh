#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行此脚本${RESET}"
    exit 1
fi

# 获取系统发行版信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_CODENAME="$VERSION_CODENAME"
else
    echo -e "${RED}❌ 无法检测系统发行版 (/etc/os-release 不存在)${RESET}"
    exit 1
fi

# ==========================================
# 分支 A: Alpine Linux (极简安装路径)
# ==========================================
if [ "$OS_ID" = "alpine" ]; then
    echo -e "${YELLOW}🚀 检测到 Alpine Linux，执行极简初始化...${RESET}"
    
    # 仅安装用户指定的 8 核心包 + CA 证书(确保 curl 正常)
    apk update && apk upgrade
    apk add --no-cache bash curl wget vim tar sudo git gzip openssl ca-certificates
    
    echo -e "${GREEN}✅ Alpine 初始化完成！${RESET}"
    echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
    exit 0
fi

# ==========================================
# 分支 B: Debian/Ubuntu/RHEL (全功能路径)
# ==========================================

# --- 辅助函数：修复 Docker 源 ---
fix_docker_sources() {
    local sources
    sources=$(grep -rl "download.docker.com" /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ -n "$sources" ]; then
        for f in $sources; do
            [[ "$f" == *"archive_uri"* ]] && rm -f "$f" && echo -e "${GREEN}✔ 已移除冲突源: $f${RESET}"
        done
    fi
}

# --- 辅助函数：开启 BBR ---
enable_bbr() {
    echo -e "${YELLOW}🚀 检查并配置 TCP BBR...${RESET}"
    if modprobe tcp_bbr 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null
        echo -e "${GREEN}✔ BBR 开启成功${RESET}"
    else
        echo -e "${RED}⚠️ 当前内核可能不支持 BBR，跳过配置${RESET}"
    fi
}

echo -e "${GREEN}🔄 开始系统更新和依赖安装...${RESET}"

# 1. 包管理器处理
if [[ "$OS_ID" =~ debian|ubuntu ]]; then
    fix_docker_sources
    # Debian 11/12 仓库组件适配
    if [ "$OS_ID" = "debian" ]; then
        files=$(grep -rl "deb" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
        for f in $files; do
            if [[ "$OS_CODENAME" == "bullseye" ]]; then
                sed -i -r 's/\bnon-free(-firmware){0,3}\b/non-free/g' "$f"
            elif [[ "$OS_CODENAME" == "bookworm" ]]; then
                sed -i -r 's/\bnon-free non-free\b/non-free/g' "$f"
            fi
        done
    fi
    
    apt update && apt upgrade -y
    apt install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   netcat-openbsd bind9-dnsutils cron systemd-timesyncd vim gzip bash
    
    # 时区与服务
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true
    systemctl enable --now cron systemd-timesyncd

elif [[ "$OS_ID" =~ fedora|centos|rhel|rocky|almalinux ]]; then
    yum upgrade -y || dnf upgrade -y
    yum install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   nc bind-utils cronie vim gzip bash || \
    dnf install -y curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl \
                   nc bind-utils cronie vim gzip bash
    
    timedatectl set-timezone Asia/Shanghai
    systemctl enable --now crond
fi

# 2. 安装 NextTrace
if ! command -v nexttrace >/dev/null 2>&1; then
    echo -e "${YELLOW}🌐 安装网络追踪工具 NextTrace...${RESET}"
    curl -sL https://nxtrace.org/nt | bash
fi

# 3. 启用 BBR
enable_bbr

echo -e "---"
echo -e "${GREEN}✅ 系统初始化完成！${RESET}"
echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
