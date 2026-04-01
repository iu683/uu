#!/bin/bash
set -e

# ==========================================================
# VPS 全能一键优化脚本 - 最终完善版
# ==========================================================

# -----------------------------
# 1. 颜色与基础变量定义
# -----------------------------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"
NC="\033[0m"

LOG_FILE="/var/log/vps_setup.log"
TIMEZONE="Asia/Shanghai"
BBR_MODE="optimized"
PRIMARY_DNS_V4="8.8.8.8"
SECONDARY_DNS_V4="1.1.1.1"

# 常用工具依赖列表
deps=(curl wget git net-tools lsof tar unzip rsync pv sudo nc dnsutils iperf3 mtr jq openssl)

# -----------------------------
# 2. 基础辅助函数
# -----------------------------
log() {
    echo -e "$1"
    echo -e "$1" | sed 's/\\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

root_check() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 用户运行此脚本${RESET}"
        exit 1
    fi
}

detect_country() {
    local country=$(curl -s --max-time 5 ipinfo.io/country)
    echo "${country:-OTHER}"
}

is_kernel_version_ge() {
    local test_ver=$1
    local current_ver=$(uname -r | cut -d'-' -f1)
    if [[ "$(printf '%s\n' "$test_ver" "$current_ver" | sort -V | head -n1)" == "$test_ver" ]]; then
        return 0
    else
        return 1
    fi
}

# -----------------------------
# 3. 系统更新与依赖安装
# -----------------------------
update_system() {
    log "\n${YELLOW}=============== 1. 系统更新与依赖 ===============${RESET}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID_LOWER=${ID,,}
        if [[ "$ID_LOWER" =~ debian|ubuntu ]]; then
            OS_TYPE="debian"
            apt update && apt upgrade -y
            for pkg in "${deps[@]}"; do
                if ! dpkg -s "$pkg" &>/dev/null; then
                    if [ "$pkg" = "nc" ]; then apt install -y netcat-openbsd; 
                    elif [ "$pkg" = "iperf3" ]; then
                        echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
                        apt install -y iperf3
                    else apt install -y "$pkg"; fi
                fi
            done
        elif [[ "$ID_LOWER" =~ fedora|centos|rhel|rocky|almalinux ]]; then
            OS_TYPE="rhel"
            yum upgrade -y || dnf upgrade -y
            for pkg in "${deps[@]}"; do
                ! rpm -q "$pkg" &>/dev/null && yum install -y "$pkg"
            done
        elif [[ "$ID_LOWER" =~ alpine ]]; then
            OS_TYPE="alpine"
            apk update && apk upgrade
            for pkg in "${deps[@]}"; do
                ! apk info -e "$pkg" &>/dev/null && apk add "$pkg"
            done
        fi
    fi
}

# -----------------------------
# 4. 设置主机名为 localhost
# -----------------------------
configure_hostname() {
    log "\n${YELLOW}=============== 2. 主机名配置 ===============${NC}"
    local new_hn="localhost"
    hostnamectl set-hostname "$new_hn"
    
    # 更新 /etc/hosts 确保解析正确
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hn/" /etc/hosts
    else
        echo -e "127.0.1.1\t$new_hn" >> /etc/hosts
    fi
    log "${GREEN}✅ 主机名已设置为: $new_hn${NC}"
}

# -----------------------------
# 5. 多系统语言与字体环境 (Locale)
# -----------------------------
configure_locale() {
    log "\n${YELLOW}=============== 3. 语言环境与字体设置 ===============${RESET}"
    log "${GREEN}正在设置英文字体环境 (en_US.UTF-8)...${RESET}"
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt-get install -y locales fonts-dejavu fonts-liberation fonts-freefont-ttf
        grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen en_US.UTF-8
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        echo -e "LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8" > /etc/default/locale
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y langpacks-en glibc-all-langpacks fonts-dejavu-sans-fonts
        localectl set-locale LANG=en_US.UTF-8
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        apk add musl-locales musl-locales-lang ttf-dejavu
        export LANG=en_US.UTF-8
    fi

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    log "${GREEN}✅ 语言环境已应用完成${RESET}"
}

# -----------------------------
# 6. BBR 高性能动态配置 (优化版)
# -----------------------------
configure_bbr() {
    log "\n${YELLOW}=============== 4. BBR 高性能配置 ===============${NC}"
    local config_file="/etc/sysctl.d/99-bbr.conf"
    
    if ! is_kernel_version_ge "4.9"; then
        log "${RED}[ERROR] 内核版本过低，无法开启BBR${NC}"
        return 1
    fi
    
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local rmem_wmem somaxconn
    
    # 动态计算参数 (根据内存分级)
    if [[ $mem_mb -ge 4096 ]]; then
        rmem_wmem=67108864  # 64MB
        somaxconn=65535
    elif [[ $mem_mb -ge 1024 ]]; then
        rmem_wmem=33554432  # 32MB
        somaxconn=32768
    else
        rmem_wmem=16777216  # 16MB
        somaxconn=16384
    fi
    
    cat > "$config_file" << EOF
# --- BBR 核心 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 缓冲区优化 ---
net.core.rmem_max = ${rmem_wmem}
net.core.wmem_max = ${rmem_wmem}
net.ipv4.tcp_rmem = 4096 87380 ${rmem_wmem}
net.ipv4.tcp_wmem = 4096 65536 ${rmem_wmem}

# --- 连接队列与积压 ---
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${somaxconn}
net.core.netdev_max_backlog = ${somaxconn}

# --- 连接复用与超时 ---
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null
    log "${GREEN}✅ BBR高性能参数已应用 (内存适配: ${mem_mb}MB)${NC}"
}

# -----------------------------
# 7. 其他基础配置 (DNS, 时间, 防火墙, Docker)
# -----------------------------
configure_dns() {
    log "\n${YELLOW}=============== 5. DNS 配置 ===============${NC}"
    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        echo -e "[Resolve]\nDNS=${PRIMARY_DNS_V4} ${SECONDARY_DNS_V4}" > /etc/systemd/resolved.conf.d/99-dns.conf
        systemctl restart systemd-resolved
    else
        chattr -i /etc/resolv.conf 2>/dev/null || true
        echo -e "nameserver ${PRIMARY_DNS_V4}\nnameserver ${SECONDARY_DNS_V4}" > /etc/resolv.conf
    fi
    log "${GREEN}✅ DNS 已更新${NC}"
}


install_cron() {
    echo -e "${YELLOW}⏰ 检查并安装 cron 定时任务服务...${RESET}"

    case "$OS_TYPE" in
        debian)
            if ! dpkg -s cron >/dev/null 2>&1; then
                echo -e "${YELLOW}📦 安装 cron...${RESET}"
                apt update
                apt install -y cron
            else
                echo -e "${GREEN}✔ cron 已安装${RESET}"
            fi
            systemctl enable --now cron
            ;;
        rhel)
            if ! rpm -q cronie >/dev/null 2>&1; then
                echo -e "${YELLOW}📦 安装 cronie...${RESET}"
                yum install -y cronie 2>/dev/null || dnf install -y cronie
            else
                echo -e "${GREEN}✔ cronie 已安装${RESET}"
            fi
            systemctl enable --now crond
            ;;
        alpine)
            if ! apk info -e cronie >/dev/null 2>&1; then
                echo -e "${YELLOW}📦 安装 cronie...${RESET}"
                apk add cronie
            else
                echo -e "${GREEN}✔ cronie 已安装${RESET}"
            fi
            rc-update add crond
            service crond start
            ;;
        *)
            echo -e "${RED}❌ 未知系统类型，无法安装 cron${RESET}"
            return 1
            ;;
    esac

    # 状态检测
    if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
        echo -e "${GREEN}✔ cron 服务已运行${RESET}"
    else
        echo -e "${RED}❌ cron 服务未启动，请手动检查${RESET}"
    fi
}

# -------------------------
# 安装 NextTrace（网络路由追踪工具）
# -------------------------
install_nexttrace() {
    echo -e "${YELLOW}🌐 检查并安装 NextTrace...${RESET}"

    # 确保 curl 存在
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}❌ curl 未安装，无法安装 NextTrace${RESET}"
        return 1
    fi

    # 检测是否已安装
    if command -v nexttrace >/dev/null 2>&1; then
        echo -e "${GREEN}✔ NextTrace 已安装${RESET}"
        return 0
    fi

    echo -e "${YELLOW}👉 开始安装 NextTrace...${RESET}"

    curl -sL https://nxtrace.org/nt | bash

    # 验证
    if command -v nexttrace >/dev/null 2>&1; then
        echo -e "${GREEN}✔ NextTrace 安装成功${RESET}"
    else
        echo -e "${RED}❌ NextTrace 安装失败${RESET}"
    fi
}

enable_time_sync() {
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

configure_firewall() {
    log "\n${YELLOW}=============== 7. 防火墙全开 (多系统适配版) ===============${RESET}"
    
    # 1. 处理 firewalld (RHEL/CentOS 系)
    if command -v firewall-cmd >/dev/null 2>&1; then
        log "${BLUE}[INFO] 检测到 firewalld，正在关闭并放行所有流量...${NC}"
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
    fi

    # 2. 处理 UFW (Debian/Ubuntu 系)
    if command -v ufw >/dev/null 2>&1; then
        log "${BLUE}[INFO] 检测到 UFW，正在重置并设为全部允许...${NC}"
        # 先重置，再设为默认允许，最后开启确保规则写入，或直接 disable
        ufw --force reset
        ufw default allow incoming
        ufw default allow outgoing
        ufw disable
    fi

    # 3. 处理 nftables (新一代 Linux 常用)
    if command -v nft >/dev/null 2>&1; then
        log "${BLUE}[INFO] 检测到 nftables，正在刷新规则集...${NC}"
        nft flush ruleset
    fi

    # 4. 终极兜底：iptables (几乎所有系统都支持)
    if command -v iptables >/dev/null 2>&1; then
        log "${BLUE}[INFO] 刷新 iptables 链并设置默认策略为 ACCEPT...${NC}"
        iptables -F
        iptables -X
        iptables -t nat -F
        iptables -t nat -X
        iptables -t mangle -F
        iptables -t mangle -X
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
    fi

    # 5. IPv6 兜底 (如果存在 ip6tables)
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -F
        ip6tables -X
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
    fi

    log "${GREEN}✅ 所有已知防火墙限制已解除${RESET}"
}

docker_install() {
    log "\n${CYAN}=============== 8. Docker 环境安装 ===============${RESET}"
    local country=$(detect_country)
    if [ "$country" = "CN" ]; then
        curl -fsSL https://get.docker.com | sh --mirror Aliyun
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["https://docker.0.unsee.tech", "https://docker.1panel.live", "https://registry.dockermirror.com"]
}
EOF
    else
        curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
    
    # Docker Compose
    local latest=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    local proxy=""
    [[ "$country" == "CN" ]] && proxy="https://ghproxy.com/"
    curl -L "${proxy}https://github.com/docker/compose/releases/download/${latest:-v2.30.0}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log "${GREEN}✅ Docker & Compose 安装完成${RESET}"
}

# -----------------------------
# 8. 主流程与重启
# -----------------------------
main() {
    clear
    root_check
    
    update_system
    configure_hostname
    configure_locale
    configure_bbr
    configure_dns
    install_cron
    install_nexttrace
    enable_time_sync
    configure_firewall
    docker_install

    log "\n${GREEN}✨ 所有任务已执行完毕！${RESET}"
    log "${YELLOW}系统将在 5 秒后自动重启...${RESET}"
    
    for i in {5..1}; do
        echo -ne "${CYAN}$i... ${RESET}"
        sleep 1
    done
    echo ""
    reboot
}

main "$@"
