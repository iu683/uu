#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ==========================================
# 系统更新 & 常用依赖安装 & 修复 APT 源
# ==========================================

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


# ========================================
# Alpine 路径
# ========================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

if [ "$ID" = "alpine" ]; then
    echo -e "${YELLOW}🚀 Alpine更新与环境配置...${RESET}"

    # 更新索引并安装基础工具 + cron
    # Alpine 的 cron 包名就叫 dcron (或者使用 busybox 自带的)
    apk update && apk upgrade
    apk add --no-cache \
        bash curl wget vim tar sudo git gzip \
        openssl openssh ca-certificates tzdata \
        dcron  # 安装 cron 守护进程

    # -------------------------
    # 时区设置
    # -------------------------
    TZ=${TZ:-Asia/Shanghai}
    echo -e "${YELLOW}🌏 配置时区为: $TZ ...${RESET}"

    if [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        echo "$TZ" > /etc/timezone
        echo -e "${GREEN}✔ 时区设置完成${RESET}"
    else
        echo -e "${RED}❌ 时区不存在: $TZ${RESET}"
    fi

    # -------------------------
    # Cron 服务配置
    # -------------------------
    echo -e "${YELLOW}⏰ 正在启动 Cron 服务...${RESET}"
    
    # 确保 cron 目录存在
    mkdir -p /var/spool/cron/crontabs

    # 判断运行环境启动 crond
    # 如果在 Docker 中，通常需要手动启动；如果在物理机/虚拟机，可用 rc-service
    if [ -f /run/openrc/softlevel ]; then
        # 针对普通 Alpine 系统 (OpenRC)
        rc-update add dcron default
        rc-service dcron start
    else
        # 针对 Docker 容器环境
        # 后台启动 crond
        crond -b -L /var/log/cron.log
    fi

    echo -e "${GREEN}✅ Alpine 更新完成${RESET}"
    echo -e "${YELLOW}当前时间: $(date +'%Y-%m-%d %H:%M:%S')${RESET}"

    exit 0
fi
# -------------------------
# 常用依赖
# -------------------------
deps=(curl wget git net-tools lsof tar unzip rsync pv sudo iperf3 mtr jq openssl)

# -------------------------
# 检查并安装依赖（兼容不同系统）
# -------------------------
check_and_install() {
    local check_cmd="$1"
    local install_cmd="$2"
    local missing=()
    for pkg in "${deps[@]}"; do
        if ! eval "$check_cmd \"$pkg\"" &>/dev/null; then
            missing+=("$pkg")
        else
            echo -e "${GREEN}✔ 已安装: $pkg${RESET}"
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}👉 安装缺失依赖: ${missing[*]}${RESET}"
        # Debian 系统处理 netcat
        if [ "$OS_TYPE" = "debian" ]; then
            # 让 iperf3 安装时自动选择 No（不启动 daemon）
            echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
            for pkg in "${missing[@]}"; do
                if [ "$pkg" = "nc" ]; then
                    apt install -y netcat-openbsd
                else
                    apt install -y "$pkg"
                fi
            done
        else
            eval "$install_cmd \"\${missing[@]}\""
        fi
    fi
}

# -------------------------
# 清理重复 Docker 源
# -------------------------
fix_duplicate_docker_sources() {
    echo -e "${YELLOW}🔍 检查重复 Docker APT 源...${RESET}"
    local docker_sources
    docker_sources=$(grep -rl "download.docker.com" /etc/apt/sources.list.d/ 2>/dev/null || true)
    if [ "$(echo "$docker_sources" | grep -c .)" -gt 1 ]; then
        echo -e "${RED}⚠️ 检测到重复 Docker 源:${RESET}"
        echo "$docker_sources"
        for f in $docker_sources; do
            if [[ "$f" == *"archive_uri"* ]]; then
                rm -f "$f"
                echo -e "${GREEN}✔ 删除多余源: $f${RESET}"
            fi
        done
    else
        echo -e "${GREEN}✔ Docker 源正常${RESET}"
    fi
}

# -------------------------
# 修复 sources.list（兼容 Bullseye / Bookworm）
# -------------------------
fix_sources_for_version() {
    echo -e "${YELLOW}🔍 修复 sources.list 兼容性...${RESET}"
    local version="$1"
    local files
    files=$(grep -rl "deb" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
    for f in $files; do
        if [[ "$version" == "bullseye" ]]; then
            sed -i -r 's/\bnon-free(-firmware){0,3}\b/non-free/g' "$f"
            sed -i '/deb .*bullseye-backports/s/^/##/' "$f"
        elif [[ "$version" == "bookworm" ]]; then
            # Bookworm 保留 non-free-firmware，但去掉重复 non-free
            sed -i -r 's/\bnon-free non-free\b/non-free/g' "$f"
        fi
    done
    echo -e "${GREEN}✔ sources.list 已优化${RESET}"
}

# -------------------------
# 系统更新函数
# -------------------------
update_system() {
    echo -e "${GREEN}🔄 检测系统发行版并更新...${RESET}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "${YELLOW}👉 当前系统: $PRETTY_NAME${RESET}"

        # 系统类型
        if [[ "$ID" =~ debian|ubuntu ]]; then
            OS_TYPE="debian"
            fix_duplicate_docker_sources
            if [[ "$ID" == "debian" ]]; then
                fix_sources_for_version "$VERSION_CODENAME"
            fi
            apt update && apt upgrade -y
            check_and_install "dpkg -s" "apt install -y"
        elif [[ "$ID" =~ fedora ]]; then
            OS_TYPE="rhel"
            dnf check-update || true
            dnf upgrade -y
            check_and_install "rpm -q" "dnf install -y"
        elif [[ "$ID" =~ centos|rhel ]]; then
            OS_TYPE="rhel"
            yum check-update || true
            yum upgrade -y
            check_and_install "rpm -q" "yum install -y"
        elif [[ "$ID" =~ alpine ]]; then
            OS_TYPE="alpine"
            apk update && apk upgrade
            check_and_install "apk info -e" "apk add"
        else
            echo -e "${RED}❌ 暂不支持的 Linux 发行版: $ID${RESET}"
            return 1
        fi
    else
        echo -e "${RED}❌ 无法检测系统发行版 (/etc/os-release 不存在)${RESET}"
        return 1
    fi

    echo -e "${GREEN}✅ 系统更新和依赖安装完成！${RESET}"
}


install_netcat() {
    echo -e "${YELLOW}🔍 检查 netcat...${RESET}"

    if command -v nc >/dev/null 2>&1; then
        echo -e "${GREEN}✔ nc 已安装${RESET}"
        return
    fi

    echo -e "${YELLOW}👉 安装 netcat-openbsd...${RESET}"

    if [ "$OS_TYPE" = "debian" ]; then
        apt install -y netcat-openbsd
    elif [ "$OS_TYPE" = "rhel" ]; then
        yum install -y nc 2>/dev/null || dnf install -y nc
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk add netcat-openbsd
    else
        echo -e "${RED}❌ 未知系统，无法安装 nc${RESET}"
        return 1
    fi

    if command -v nc >/dev/null 2>&1; then
        echo -e "${GREEN}✔ nc 安装成功${RESET}"
    else
        echo -e "${RED}❌ nc 安装失败${RESET}"
    fi
}

install_dnsutils() {
    echo -e "${YELLOW}🔍 检查 DNS 工具(dnsutils)...${RESET}"

    if command -v dig >/dev/null 2>&1; then
        echo -e "${GREEN}✔ DNS 工具已安装${RESET}"
        return
    fi

    echo -e "${YELLOW}👉 安装 DNS 工具...${RESET}"

    if [ "$OS_TYPE" = "debian" ]; then
        apt install -y bind9-dnsutils
    elif [ "$OS_TYPE" = "rhel" ]; then
        yum install -y bind-utils 2>/dev/null || dnf install -y bind-utils
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk add bind-tools
    else
        echo -e "${RED}❌ 未知系统，无法安装 DNS 工具${RESET}"
        return 1
    fi

    if command -v dig >/dev/null 2>&1; then
        echo -e "${GREEN}✔ DNS 工具安装成功${RESET}"
    else
        echo -e "${RED}❌ DNS 工具安装失败${RESET}"
    fi
}
# -------------------------
# 安装并启动 cron
# -------------------------
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

# -------------------------
# 开启 BBR（安全版）
# -------------------------
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

# -------------------------
# 时间同步 & 设置上海时区（Debian / Ubuntu 专用）
# -------------------------
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

# -------------------------
# 执行
# -------------------------
clear
update_system
install_netcat
install_dnsutils
install_cron
install_nexttrace
enable_bbr
enable_time_sync
