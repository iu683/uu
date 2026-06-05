#!/bin/bash
# ==========================================
# 一键开放 VPS 所有端口
# ⚠️ 警告：非常不安全，仅用于测试环境
# ==========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# --------------------------
# 检查 Root 权限
# --------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限或 sudo 运行此脚本！${RESET}"
    exit 1
fi

echo -e "${YELLOW}检测防火墙类型...${RESET}"

# --------------------------
# 自动安装函数
# --------------------------
install_package() {
    local pkg="$1"
    if [[ -f /etc/alpine-release ]]; then
        echo -e "${YELLOW}检测到 Alpine，尝试安装 $pkg ...${RESET}"
        apk update && apk add "$pkg"
    elif [[ -f /etc/debian_version ]]; then
        echo -e "${YELLOW}检测到 Debian/Ubuntu，尝试安装 $pkg ...${RESET}"
        apt-get update && apt-get install -y "$pkg"
    elif [[ -f /etc/redhat-release ]]; then
        echo -e "${YELLOW}检测到 CentOS/RHEL/Fedora，尝试安装 $pkg ...${RESET}"
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "$pkg"
        else
            yum install -y "$pkg"
        fi
    else
        echo -e "${RED}❌ 未知系统，请手动安装 $pkg${RESET}"
        exit 1
    fi
}

# --------------------------
# 检测防火墙类型
# --------------------------
# 优先检测已经运行或安装的防火墙
if command -v ufw >/dev/null 2>&1; then
    FW_TYPE="ufw"
elif command -v iptables >/dev/null 2>&1; then
    FW_TYPE="iptables"
elif command -v nft >/dev/null 2>&1; then
    FW_TYPE="nftables"
else
    # 未检测到任何防火墙时，根据系统按需安装
    if [[ -f /etc/alpine-release ]]; then
        install_package nftables
        FW_TYPE="nftables"
        # 写入一个基础的全放通规则防止启动失败
        echo 'flush ruleset; table inet filter { chain input { type filter hook input priority 0; policy accept; }; }' > /etc/nftables.nft
        rc-update add nftables >/dev/null 2>&1
        service nftables start >/dev/null 2>&1
    elif [[ -f /etc/debian_version ]]; then
        install_package ufw
        FW_TYPE="ufw"
    elif [[ -f /etc/redhat-release ]]; then
        install_package iptables
        FW_TYPE="iptables"
    else
        echo -e "${RED}❌ 未知系统，无法判断/安装防火墙${RESET}"
        exit 1
    fi
fi

# --------------------------
# 开放所有端口逻辑
# --------------------------
echo -e "${GREEN}检测到系统防火墙组件: $FW_TYPE，开始清空规则...${RESET}"

if [[ "$FW_TYPE" == "ufw" ]]; then
    # 既然是要开放所有端口，最稳妥的做法是直接禁用 UFW
    ufw disable >/dev/null 2>&1
    ufw --force reset >/dev/null 2>&1
    echo -e "${GREEN}✓ UFW 已禁用并重置（默认放行所有流量）${RESET}"

elif [[ "$FW_TYPE" == "iptables" ]]; then
    # 清空所有规则并设置默认策略为 ACCEPT
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -t raw -F
    iptables -t raw -X
    
    # 如果存在 ip6tables（IPv6），同步放通
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -F
        ip6tables -X
    fi
    echo -e "${GREEN}✓ iptables 规则已清空，默认策略已设为 ACCEPT (IPv4/IPv6)${RESET}"

elif [[ "$FW_TYPE" == "nftables" ]]; then
    # 彻底刷新 nftables 规则集
    nft flush ruleset
    nft add table inet filter
    nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
    nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
    nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
    echo -e "${GREEN}✓ nftables 规则集已重置为全放行 (ACCEPT)${RESET}"
fi

# --------------------------
# 提示与警告
# --------------------------
echo -e "${RED}==================================================${RESET}"
echo -e "${YELLOW}警告：VPS 本地防火墙已完全关闭/放通！${RESET}"
echo -e "${YELLOW}提示：如果依然无法访问，请务必检查：${RESET}"
echo -e "${YELLOW}云服务商控制台（阿里云/腾讯云/AWS等）的「安全组/防火墙」是否放行。${RESET}"
echo -e "${RED}==================================================${RESET}"
