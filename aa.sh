#!/bin/bash
set -e

# ==========================================================
# VPS 全能一键优化脚本 
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
PRIMARY_DNS_V6="2606:4700:4700::1111"
SECONDARY_DNS_V6="2001:4860:4860::8888"
non_interactive=${NON_INTERACTIVE:-false}

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

# 简单的进度旋转动画
start_spinner() {
    echo -n "$1"
    sleep 0.1
}

stop_spinner() {
    echo -e "${GREEN}完成${RESET}"
}

# 检查磁盘剩余空间 (单位: MB)
check_disk_space() {
    local required_mb=$1
    local available_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        log "${RED}❌ 磁盘空间不足 (剩余 ${available_mb}MB, 需要 ${required_mb}MB)${RESET}"
        return 1
    fi
    return 0
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

configure_firewall() {
    log "\n${YELLOW}=============== 4. 防火墙全开===============${RESET}"
    
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


# -----------------------------
# 6. BBR 高性能动态配置 (优化版)
# -----------------------------
configure_bbr() {
    log "\n${YELLOW}=============== 5. BBR 调优配置 ===============${NC}"
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
    log "${GREEN}✅ BBR调优参数已应用 (内存适配: ${mem_mb}MB)${NC}"
}

# -----------------------------
# 7. 其他基础配置 (DNS, 时间, Docker)
# -----------------------------

configure_dns() {
    log "\n${YELLOW}=============== 6. DNS 配置 ===============${NC}"
    
    # 构造 DNS 列表字符串
    local dns_v4="${PRIMARY_DNS_V4} ${SECONDARY_DNS_V4}"
    local dns_v6="${PRIMARY_DNS_V6} ${SECONDARY_DNS_V6}"

    if systemctl is-active --quiet systemd-resolved; then
        log "${BLUE}[INFO] 检测到 systemd-resolved，正在写入配置...${NC}"
        mkdir -p /etc/systemd/resolved.conf.d
        
        # 写入 systemd 专用的配置格式
        cat > /etc/systemd/resolved.conf.d/99-dns.conf << EOF
[Resolve]
DNS=${dns_v4} ${dns_v6}
FallbackDNS=8.8.44.44 2001:4860:4860::8844
EOF
        systemctl restart systemd-resolved
    else
        log "${BLUE}[INFO] 正在修改传统 /etc/resolv.conf...${NC}"
        # 解锁文件防止由于之前的脚本锁定导致写入失败
        chattr -i /etc/resolv.conf 2>/dev/null || true
        
        # 写入 nameserver 列表
        {
            echo "# Generated by VPS Setup Script"
            echo "nameserver ${PRIMARY_DNS_V4}"
            echo "nameserver ${SECONDARY_DNS_V4}"
            echo "nameserver ${PRIMARY_DNS_V6}"
            echo "nameserver ${SECONDARY_DNS_V6}"
        } > /etc/resolv.conf
        
        # 可选：如果你希望锁定 DNS 不被 DHCP 覆盖，可以取消下行的注释
        # chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
    
    log "${GREEN}✅ DNS 已更新 (IPv4: ${PRIMARY_DNS_V4} ${SECONDARY_DNS_V4}, IPv6: ${PRIMARY_DNS_V6} ${SECONDARY_DNS_V6})${NC}"
}


# -----------------------------
# 6. Swap 配置 (固定 1GB，且磁盘需 > 5GB)
# -----------------------------
configure_swap() {
    log "\n${YELLOW}=============== 7. Swap配置 ===============${NC}"
    
    # --- 新增判断：磁盘空间小于 5GB 则跳过 ---
    # 获取根目录剩余空间 (单位: MB)
    local free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [[ "$free_space" -lt 5120 ]]; then
        log "${YELLOW}磁盘空间小于 5GB (剩余 ${free_space}MB)，为防止空间耗尽，跳过 Swap 配置。${NC}"
        return 0
    fi

    [[ "$SWAP_SIZE_MB" = "0" ]] && { log "${BLUE}Swap已禁用${NC}"; return; }

    local swap_mb=1024  # 固定 1GB
    log "${BLUE}设置Swap: ${swap_mb}MB${NC}"

    # 检查磁盘空间（确保创建 1GB 后还有 100MB 缓冲）
    check_disk_space $((swap_mb + 100)) || return 1

    # 已有 swap 检测
    if swapon --show | grep -q '^/'; then
        log "${BLUE}系统已有Swap，跳过创建${NC}"
        return
    fi

    local swap_file="/swapfile"
    if [[ -f "$swap_file" ]]; then
        swapoff "$swap_file" 2>/dev/null || true
        rm -f "$swap_file"
    fi

    log "${BLUE}创建${swap_mb}MB Swap文件...${NC}"
    if command -v fallocate &>/dev/null; then
        start_spinner "快速创建Swap... "
        fallocate -l "${swap_mb}M" "$swap_file" >> "$LOG_FILE" 2>&1
        stop_spinner
    else
        log "${BLUE}使用dd创建，请稍候...${NC}"
        dd if=/dev/zero of="$swap_file" bs=1M count="$swap_mb" status=progress 2>&1
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file" >> "$LOG_FILE" 2>&1
    swapon "$swap_file" >> "$LOG_FILE" 2>&1
    grep -q "$swap_file" /etc/fstab || echo "$swap_file none swap sw 0 0" >> /etc/fstab

    # 设置 swappiness
    sysctl vm.swappiness=10
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf

    log "${GREEN}✅ ${swap_mb}MB Swap已配置${NC}"
}
# -----------------------------
# 7. SSH 配置
# -----------------------------
configure_ssh() {
    log "\n${YELLOW}=============== 8. SSH配置 ===============${NC}"
    
    [[ -z "$NEW_SSH_PORT" ]] && [[ "$non_interactive" = false ]] && { read -p "SSH端口 (留空跳过): " -r NEW_SSH_PORT < /dev/tty; }
    if [[ -z "$NEW_SSH_PASSWORD" ]] && [[ "$non_interactive" = false ]]; then
        read -s -p "root密码 (输入时不可见, 留空跳过): " NEW_SSH_PASSWORD < /dev/tty
        echo
    fi

    local ssh_changed=false
    if [[ -n "$NEW_SSH_PORT" && "$NEW_SSH_PORT" =~ ^[0-9]+$ && "$NEW_SSH_PORT" -gt 0 && "$NEW_SSH_PORT" -lt 65536 ]]; then
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d)"
        sed -i '/^[#\s]*Port\s\+/d' /etc/ssh/sshd_config
        echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
        ssh_changed=true
        log "${GREEN}✅ SSH端口设为: ${NEW_SSH_PORT}${NC}"
    fi
    
    if [[ -n "$NEW_SSH_PASSWORD" ]]; then
        echo "root:${NEW_SSH_PASSWORD}" | chpasswd >> "$LOG_FILE" 2>&1
        log "${GREEN}✅ root密码已设置${NC}"
    fi

    if [[ "$ssh_changed" = true ]]; then
        if sshd -t 2>>"$LOG_FILE"; then
            systemctl restart sshd >> "$LOG_FILE" 2>&1 || systemctl restart ssh >> "$LOG_FILE" 2>&1
            log "${YELLOW}[WARN] SSH端口已更改，请用新端口重连！${NC}"
        else
            log "${RED}[ERROR] SSH配置错误，已恢复备份${NC}"
            cp "/etc/ssh/sshd_config.backup.$(date +%Y%m%d)" /etc/ssh/sshd_config
            systemctl restart sshd >> "$LOG_FILE" 2>&1 || true
        fi
    fi
}


# -----------------------------
# 8.5 SSH 密钥与安全深度加固 (修复变量并默认 N)
# -----------------------------
configure_ssh_security() {
    log "\n${YELLOW}=============== 8.5 SSH 密钥与安全加固 ===============${NC}"
    
    # 定义局部变量，防止外部变量为空导致 cp 报错
    local ssh_conf="/etc/ssh/sshd_config"
    local keypath="/root/.ssh/id_ed25519"

    # 1. 交互判断：非交互模式下默认跳过
    if [[ "$non_interactive" = false ]]; then
        # [y/N] 表示回车默认为 No
        read -p "是否配置 SSH 密钥登录并禁用密码登录? [y/n]: " -r SETUP_KEY
        
        # 只要输入的不是 y 或 Y（包括直接回车），就视为取消
        if [[ ! "$SETUP_KEY" =~ ^[yY]$ ]]; then
            log "${BLUE}已取消 SSH 密钥加固${NC}"
            return 0
        fi
    else
        log "${BLUE}非交互模式，自动跳过 SSH 密钥加固${NC}"
        return 0
    fi

    # --- 用户确认 [y] 后开始执行 ---
    
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # 2. 生成 Ed25519 密钥对
    log "${BLUE}正在生成密钥对: ${keypath}${NC}"
    if [ ! -f "$keypath" ]; then
        ssh-keygen -t ed25519 -f "$keypath" -N "" -q
    fi

    # 3. 写入公钥
    cat "${keypath}.pub" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    # 4. 修改 SSH 配置 (使用本地变量保证 cp 正常)
    if [[ -f "$ssh_conf" ]]; then
        cp "$ssh_conf" "${ssh_conf}.bak_security"
        
        log "${BLUE}正在修改 SSH 配置: 启用密钥认证，禁用密码登录...${NC}"
        # 强制开启密钥认证
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$ssh_conf"
        # 禁用 root 密码登录
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/g' "$ssh_conf"
        # 禁用普通密码验证
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' "$ssh_conf"
    else
        log "${RED}❌ 未找到 SSH 配置文件: $ssh_conf${NC}"
        return 1
    fi

    # 5. 语法检查并重启
    if sshd -t; then
        if systemctl is-active --quiet sshd; then
            systemctl restart sshd
        else
            systemctl restart ssh
        fi
        log "${GREEN}✅ SSH 安全加固完成${NC}"
        
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}   重要提示：请务必保存下方的私钥内容到本地电脑！${NC}"
        echo -e "${RED}   由于您禁用了密码登录，丢失此私钥将导致无法再次进入服务器。${NC}"
        echo -e "${CYAN}------------------- 私钥开始 (PRIVATE KEY) -------------------${NC}"
        cat "$keypath"
        echo -e "${CYAN}-------------------- 私钥结束 (END KEY) ---------------------${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        if [[ "$non_interactive" = false ]]; then
            read -n 1 -s -r -p "确认已复制私钥？按任意键继续执行..."
            echo ""
        fi
    else
        log "${RED}❌ SSH 配置语法错误，已自动回滚备份！${NC}"
        mv "${ssh_conf}.bak_security" "$ssh_conf"
        return 1
    fi
}

# -----------------------------
# 8. Fail2ban 配置
# -----------------------------
configure_fail2ban() {
    log "\n${YELLOW}=============== 9. Fail2ban配置 ===============${NC}"

    local ports=("22")
    [[ -n "$NEW_SSH_PORT" && "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && ports+=("$NEW_SSH_PORT")
    [[ -n "$FAIL2BAN_EXTRA_PORT" && "$FAIL2BAN_EXTRA_PORT" =~ ^[0-9]+$ ]] && ports+=("$FAIL2BAN_EXTRA_PORT")
    
    # 检测非交互模式下 SSH 端口
    if [[ "$non_interactive" = true && -z "$NEW_SSH_PORT" && -f /etc/ssh/sshd_config ]]; then
        local detected_port=$(grep -oP '^\s*Port\s+\K\d+' /etc/ssh/sshd_config | tail -n1)
        [[ -n "$detected_port" ]] && ports+=("$detected_port")
    fi
    
    local port_list=$(printf "%s\n" "${ports[@]}" | sort -un | tr '\n' ',' | sed 's/,$//')

    start_spinner "安装Fail2ban... "
    case "$OS_TYPE" in
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >> "$LOG_FILE" 2>&1 ;;
        rhel) yum install -y fail2ban >> "$LOG_FILE" 2>&1 ;;
        alpine) apk add fail2ban >> "$LOG_FILE" 2>&1 ;;
    esac
    stop_spinner

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 86400
findtime = 300
maxretry = 3
backend = systemd
ignoreip = 127.0.0.1/8
logtarget = /var/log/fail2ban.log

[sshd]
enabled = true
port = ${port_list}
maxretry = 3
EOF

    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl start fail2ban >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet fail2ban; then
        log "${GREEN}✅ Fail2ban已启动，保护端口: ${port_list}${NC}"
    else
        log "${RED}[ERROR] Fail2ban启动失败${NC}"
    fi
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

docker_install() {
    log "\n${CYAN}============ 10. Docker 环境安装 ============${RESET}"
    
    # 交互判断逻辑
    if [[ "$non_interactive" = false ]]; then
        read -p "是否安装 Docker 和 Docker Compose? [y/n]: " -r INSTALL_DOCKER
        # 默认为 Y，只有输入 n 或 N 时才跳过
        [[ "$INSTALL_DOCKER" =~ ^[nN]$ ]] && { log "${YELLOW}已取消 Docker 安装${RESET}"; return 0; }
    fi

    local country=$(detect_country)
    
    # 1. 安装 Docker 引擎
    if [ "$country" = "CN" ]; then
        log "${BLUE}检测到环境在国内，使用阿里云镜像加速安装...${RESET}"
        curl -fsSL https://get.docker.com | sh --mirror Aliyun
        
        # 配置国内镜像加速器
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": [
    "https://docker.0.unsee.tech",
    "https://docker.1panel.live",
    "https://registry.dockermirror.com",
    "https://docker.m.daocloud.io"
  ]
}
EOF
    else
        log "${BLUE}使用官方源安装 Docker...${RESET}"
        curl -fsSL https://get.docker.com | sh
    fi

    # 启动并自启
    systemctl enable --now docker >> "$LOG_FILE" 2>&1
    
    # 2. 安装 Docker Compose
    log "${BLUE}正在获取 Docker Compose 最新版本...${RESET}"
    local latest=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    local proxy=""
    
    # 如果在国内，使用 ghproxy 加速下载 GitHub Release
    [[ "$country" == "CN" ]] && proxy="https://v6.gh-proxy.org/"
    
    # 这里的 v2.30.0 是兜底版本号
    local download_url="${proxy}https://github.com/docker/compose/releases/download/${latest:-v2.30.0}/docker-compose-$(uname -s)-$(uname -m)"
    
    if curl -L "$download_url" -o /usr/local/bin/docker-compose; then
        chmod +x /usr/local/bin/docker-compose
        log "${GREEN}✅ Docker & Compose 安装完成${RESET}"
    else
        log "${RED}❌ Docker Compose 下载失败，请检查网络${RESET}"
    fi
}

# -----------------------------
# 11. 系统垃圾清理
# -----------------------------
clean_system() {
    log "\n${YELLOW}=============== 11. 系统垃圾清理 ============${NC}"
    
    case "$OS_TYPE" in
        debian)
            log "${BLUE}正在清理 Debian/Ubuntu 缓存...${NC}"
            apt-get autoremove -y >> "$LOG_FILE" 2>&1
            apt-get autoclean -y >> "$LOG_FILE" 2>&1
            apt-get clean -y >> "$LOG_FILE" 2>&1
            ;;
        rhel)
            log "${BLUE}正在清理 RHEL/CentOS 缓存...${NC}"
            yum autoremove -y >> "$LOG_FILE" 2>&1
            yum clean all >> "$LOG_FILE" 2>&1
            ;;
        alpine)
            log "${BLUE}正在清理 Alpine 缓存...${NC}"
            rm -rf /var/cache/apk/*
            ;;
    esac

    log "${BLUE}正在清理临时文件与系统日志...${NC}"
    # 清理日志文件 (保留目录结构，清空内容)
    find /var/log -type f -regex '.*\.gz$\|.*\.[0-9]$.*\.log$' -exec truncate -s 0 {} + 2>/dev/null || true
    
    # 清理临时目录
    rm -rf /tmp/* /var/tmp/*
    
    # 清理命令历史 (可选)
    history -c
    
    log "${GREEN}✅ 系统清理完成${NC}"
}

# -----------------------------
# 显示 VPS 信息 (智能版)
# -----------------------------
show_vps_info() {
    # 获取实际Swap大小（通用方法）
    local swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    local swap_display="$((swap_kb/1024))MB"


    # SSH端口检测
    local ssh_display
    if [[ -n "$NEW_SSH_PORT" ]]; then
        ssh_display="$NEW_SSH_PORT"
    elif [[ -f /etc/ssh/sshd_config ]]; then
        ssh_display=$(grep -oP '^\s*Port\s+\K\d+' /etc/ssh/sshd_config | tail -n1)
        ssh_display="${ssh_display:-22}"
    else
        ssh_display="22"
    fi

    # Fail2ban状态
    local fail2ban_display
    if systemctl is-active --quiet fail2ban; then
        fail2ban_display="已启用"
    else
        fail2ban_display="未启用"
    fi

    # BBR状态检测
    local bbr_display
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q 'bbr'; then
        bbr_display="已启用"
    else
        bbr_display="未启用"
    fi
    
    # Docker状态检测
    local docker_display
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            docker_display="已启用"
        else
            docker_display="已安装但未启用"
        fi
    else
        docker_display="未安装"
    fi

    local hostname_display="${NEW_HOSTNAME:-$(hostname)}"
    local dns_v4_display="${PRIMARY_DNS_V4:-8.8.8.8}, ${SECONDARY_DNS_V4:-1.1.1.1}"
    local dns_v6_display="${PRIMARY_DNS_V6:-2606:4700:4700::1111}"

    echo -e "${CYAN}================== VPS信息 ==================${NC}"
    echo -e "${YELLOW}主机名: ${hostname_display}${NC}"
    echo -e "${YELLOW}时区: ${TIMEZONE:-Asia/Shanghai}${NC}"
    echo -e "${YELLOW}Swap: ${swap_display}${NC}"
    echo -e "${YELLOW}BBR: ${bbr_display}${NC}"
    echo -e "${YELLOW}DNS (IPv4): ${dns_v4_display}${NC}"
    echo -e "${YELLOW}DNS (IPv6): ${dns_v6_display}${NC}"
    echo -e "${YELLOW}Fail2ban: ${fail2ban_display}${NC}"
    echo -e "${YELLOW}Docker: ${docker_display}${NC}"
    echo -e "${YELLOW}SSH端口: ${ssh_display}${NC}"
    echo -e "${CYAN}==============================================${NC}"
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
    configure_firewall
    configure_dns
    configure_swap
    configure_ssh
    configure_ssh_security
    configure_fail2ban
    install_cron
    install_nexttrace
    enable_time_sync
    docker_install
    clean_system

    show_vps_info

    log "${GREEN}✨ 所有任务已执行完毕！${RESET}"
    log "${YELLOW}系统将在 5 秒后自动重启...${RESET}"
    
    for i in {5..1}; do
        echo -ne "${CYAN}$i... ${RESET}"
        sleep 1
    done
    echo ""
    reboot
}

main "$@"
