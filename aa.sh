#!/bin/bash
# ==========================================
# 一键开放 VPS 所有端口
# 支持: Debian 10-13, Ubuntu, CentOS/RHEL, Alpine
# 警告：此操作将关闭系统防火墙，仅建议用于测试环境！
# ==========================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须以 root 权限运行此脚本！${RESET}"
    exit 1
fi

# 2. 检查系统类型
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
    echo -e "${YELLOW}正在尝试安装缺失的组件: $pkg ...${RESET}"
    case "$OS" in
        alpine)
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

case "$OS" in
    "alpine")
        if command -v nft >/dev/null 2>&1; then
            echo -e "${GREEN}配置 nftables...${RESET}"
            nft flush ruleset
            nft add table inet filter
            nft add chain inet filter input { type filter hook input priority 0 \; policy accept \; }
            rc-update add nftables default 2>/dev/null || true
        elif command -v iptables >/dev/null 2>&1; then
            iptables -P INPUT ACCEPT && iptables -F && iptables -X
            /etc/init.d/iptables save 2>/dev/null || true
        fi
        ;;

    "debian")
        # Debian/Ubuntu 逻辑优化
        if command -v ufw >/dev/null 2>&1; then
            ufw disable
            echo -e "${GREEN}UFW 防火墙已禁用${RESET}"
        elif command -v nft >/dev/null 2>&1; then
            # 针对 Debian 12/13 的核心处理
            echo -e "${GREEN}检测到 nftables，正在清空规则...${RESET}"
            nft flush ruleset
            nft add table inet filter 2>/dev/null || true
            nft add chain inet filter input { type filter hook input priority 0 \; policy accept \; } 2>/dev/null || true
        else
            # 如果都没有，则安装 iptables 兜底
            install_package iptables
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -F
            iptables -X
        fi
        ;;

    "rhel")
        if command -v firewalld >/dev/null 2>&1; then
            systemctl stop firewalld
            systemctl disable firewalld
            echo -e "${GREEN}Firewalld 已停止并禁用${RESET}"
        fi
        # 无论是否有 firewalld，均尝试清空 iptables 以防万一
        if command -v iptables >/dev/null 2>&1; then
            iptables -P INPUT ACCEPT && iptables -F
        fi
        ;;

    *)
        echo -e "${RED}无法识别的操作系统，尝试使用通用 iptables 清理...${RESET}"
        if command -v iptables >/dev/null 2>&1; then
            iptables -P INPUT ACCEPT && iptables -F
        else
            echo -e "${RED}未找到任何防火墙工具。${RESET}"
        fi
        ;;
esac

# --------------------------
# 结束提示
# --------------------------
echo -e "${GREEN}----------------------------------${RESET}"
echo -e "${GREEN}✅ 所有内部防火墙规则已尝试清空并开放！${RESET}"
echo -e "${YELLOW}提示：如果端口仍无法访问，请检查您的云服务商控制台（安全组/防火墙策略）。${RESET}"
