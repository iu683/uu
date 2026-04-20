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
    OS_VER="$VERSION_ID"
else
    echo -e "${RED}❌ 无法识别系统${RESET}"
    exit 1
fi

# ========================================
# 分支 1: Alpine 极简路径
# ========================================
if [ "$OS_ID" = "alpine" ]; then
    echo -e "${YELLOW}🚀 Alpine 极简更新...${RESET}"
    apk update && apk upgrade
    apk add --no-cache bash curl wget vim tar sudo git gzip openssl openssh ca-certificates tzdata
    
    # ✅ Alpine 专用时区设置逻辑
    echo -e "${YELLOW}🌏 配置时区为 上海 (Asia/Shanghai)...${RESET}"
    
    # 先删除旧文件，防止 cp 或 ln 报错
    rm -f /etc/localtime
    
    # 使用软链接，这是 Linux 通用标准
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    
    # 写入配置文件
    echo "Asia/Shanghai" > /etc/timezone
    
    echo -e "${GREEN}✅ Alpine 更新完成${RESET}"
    echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
    exit 0
fi

# ========================================
# 工具函数
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
        sed -i -r 's/\bnon-free(-firmware)?\b/non-free non-free-firmware/g' "$f"
        sed -i 's/non-free-firmware non-free-firmware/non-free-firmware/g' "$f"
    done
}

install_base() {
    echo -e "${GREEN}📦 安装组件 (Debian/Ubuntu)...${RESET}"
    apt update && apt upgrade -y
    apt install -y curl wget git vim sudo bash gzip tar unzip rsync \
        net-tools lsof iperf3 mtr jq openssl \
        netcat-openbsd bind9-dnsutils cron systemd-timesyncd tzdata || true
    systemctl enable --now cron || true
}

install_rhel() {
    echo -e "${GREEN}📦 安装组件 (RHEL/CentOS)...${RESET}"
    pkg_mgr=$(command -v dnf || echo "yum")
    $pkg_mgr upgrade -y
    $pkg_mgr install -y curl wget git vim sudo bash gzip tar unzip rsync \
        net-tools lsof iperf3 mtr jq openssl nc bind-utils cronie tzdata
    systemctl enable --now crond || true
}


set_timezone() {
    echo -e "${YELLOW}⏰ 配置 systemd-timesyncd 时间同步& 设置上海时区...${RESET}"

    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}❌ 无法识别系统类型${RESET}"
        return 1
    fi

    . /etc/os-release

    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        echo -e "${RED}❌ 当前系统不是 Debian/Ubuntu，跳过时间同步配置${RESET}"
        return 0
    fi

    echo -e "${GREEN}✔ 系统检测通过：$PRETTY_NAME${RESET}"

    # 安装 systemd-timesyncd（极简系统可能没装）
    if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
        echo -e "${YELLOW}📦 安装 systemd-timesyncd...${RESET}"
        apt update
        apt install -y systemd-timesyncd
    else
        echo -e "${GREEN}✔ systemd-timesyncd 已安装${RESET}"
    fi

    # 启用服务
    systemctl unmask systemd-timesyncd || true
    systemctl enable --now systemd-timesyncd

    # 启用 NTP
    timedatectl set-ntp true
    systemctl restart systemd-timesyncd

     # 设置上海时区
    timedatectl set-timezone Asia/Shanghai
    echo -e "${GREEN}✔ 时区已设置为上海 (Asia/Shanghai)${RESET}"

    # 状态检查
    if systemctl is-active --quiet systemd-timesyncd; then
        echo -e "${GREEN}✔ 时间同步服务已成功启动${RESET}"
    else
        echo -e "${RED}❌ 时间同步服务启动失败${RESET}"
    fi
}

enable_bbr() {
    echo -e "${YELLOW}🚀 检查并配置 TCP BBR...${RESET}"

    # 1️⃣ 尝试加载 BBR 模块
    if ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${RED}❌ 当前内核未编译 BBR 或不支持${RESET}"
        return 1
    fi

    # 2️⃣ 写入模块自动加载（避免重复）
    mkdir -p /etc/modules-load.d
    if ! grep -qxF "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi

    # 3️⃣ 检查是否已经启用
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        echo -e "${GREEN}✔ BBR 已经开启，无需修改${RESET}"
        return 0
    fi

    echo -e "${YELLOW}👉 BBR 未开启，开始配置...${RESET}"

    # 4️⃣ 写入独立 sysctl 配置文件（更规范）
    cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 5️⃣ 应用配置
    sysctl --system >/dev/null

    # 6️⃣ 再次验证
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ]; then
        echo -e "${GREEN}✔ BBR 已成功开启${RESET}"
    else
        echo -e "${RED}❌ BBR 开启失败，请检查内核配置${RESET}"
        return 1
    fi
}


install_nexttrace() {
    if command -v nexttrace >/dev/null; then
        echo -e "${GREEN}✔ NextTrace 已安装${RESET}"
        return
    fi
    echo -e "${YELLOW}🌐 安装 NextTrace...${RESET}"
    curl -sL https://nxtrace.org/nt | bash || echo -e "${RED}❌ NextTrace 安装失败${RESET}"
}

network_test() {
    echo -e "${YELLOW}🌍 网络连接测试:${RESET}"
    if curl -I -s --max-time 5 https://google.com >/dev/null; then
        echo -e "${GREEN}✔ 外网访问正常${RESET}"
    else
        echo -e "${RED}❌ 外网访问受阻${RESET}"
    fi
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
network_test

echo -e "${GREEN}----------------------------------${RESET}"
echo -e "${GREEN}✅ 更新任务全部完成！${RESET}"
echo -e "${YELLOW}系统时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
