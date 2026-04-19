#!/bin/bash
# ==========================================
# 一键开放 VPS 所有端口 (完美支持 Alpine)
# ⚠️ 警告：非常不安全，仅用于测试环境
# ==========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检查系统类型
if [[ -f /etc/alpine-release ]]; then
    OS="alpine"
elif [[ -f /etc/debian_version ]]; then
    OS="debian"
elif [[ -f /etc/redhat-release ]]; then
    OS="rhel"
else
    OS="unknown"
fi

echo -e "${YELLOW}检测到系统类型: $OS${RESET}"

# --------------------------
# 自动安装函数
# --------------------------
install_package() {
    local pkg="$1"
    case "$OS" in
        alpine)
            echo -e "${YELLOW}尝试安装 $pkg ...${RESET}"
            apk add --no-cache "$pkg"
            ;;
        debian)
            apt-get update && apt-get install -y "$pkg"
            ;;
        rhel)
            yum install -y "$pkg"
            ;;
    esac
}

# --------------------------
# 处理逻辑
# --------------------------

# 1. 针对 Alpine 的特殊优化处理 (优先使用 nftables 或 iptables)
if [[ "$OS" == "alpine" ]]; then
    # Alpine 默认通常不带 ufw，我们优先清理可能存在的 nft/iptables
    if command -v nft >/dev/null 2>&1; then
        echo -e "${GREEN}配置 nftables...${RESET}"
        nft flush ruleset
        # 设置默认策略为 ACCEPT
        nft add table inet filter
        nft add chain inet filter input { type filter hook input priority 0 \; policy accept \; }
        # 确保服务启动并加入开机自启
        rc-update add nftables default 2>/dev/null || true
        rc-service nftables start 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        echo -e "${GREEN}配置 iptables...${RESET}"
        iptables -F && iptables -X
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        # Alpine 保存 iptables 规则
        /etc/init.d/iptables save 2>/dev/null || true
    else
        echo -e "${YELLOW}未检测到防火墙，Alpine 默认状态通常为全开。${RESET}"
    fi

# 2. 针对 Debian/Ubuntu 的处理 (ufw)
elif [[ "$OS" == "debian" ]]; then
    if command -v ufw >/dev/null 2>&1; then
        ufw disable # 直接禁用防火墙在 Debian 上是最快开放所有端口的方法
        echo -e "${GREEN}UFW 已禁用 (所有端口已开放)${RESET}"
    else
        # 兜底使用 iptables
        iptables -P INPUT ACCEPT && iptables -F
    fi

# 3. 针对 RHEL/CentOS 的处理 (firewalld/iptables)
elif [[ "$OS" == "rhel" ]]; then
    if command -v firewalld >/dev/null 2>&1; then
        systemctl stop firewalld
        systemctl disable firewalld
        echo -e "${GREEN}Firewalld 已停止并禁用${RESET}"
    else
        iptables -P INPUT ACCEPT && iptables -F
    fi
fi

echo -e "${GREEN}----------------------------------${RESET}"
echo -e "${GREEN}✅ 所有端口已成功开放！${RESET}"
echo -e "${YELLOW}请注意：由于 Alpine 采用 OpenRC，如果安装了新防火墙插件，请确保已启动服务。${RESET}"
echo -e "${YELLOW}当前时间: $(date +'%Y年%m月%d日 %H:%M:%S')${RESET}"
