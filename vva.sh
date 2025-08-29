#!/bin/bash
# ==========================================
# 一键检测 & 修复 IPv6
# 适用于 Debian / Ubuntu / Alpine
# ==========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}🔍 检查 IPv6 状态...${RESET}"

# 1. 检查 IPv6 是否被禁用
disable_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
disable_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)

if [[ "$disable_all" == "1" || "$disable_default" == "1" ]]; then
    echo -e "${RED}⚠️  系统禁用了 IPv6，正在启用...${RESET}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
fi

# 2. 检查是否已有公网 IPv6
pub_ipv6=$(ip -6 addr | grep "scope global" | awk '{print $2}' | cut -d/ -f1)

if [[ -n "$pub_ipv6" ]]; then
    echo -e "${GREEN}✅ 已检测到公网 IPv6: $pub_ipv6${RESET}"
else
    echo -e "${RED}⚠️ 未检测到公网 IPv6，尝试修复...${RESET}"

    if command -v netplan >/dev/null 2>&1; then
        # Debian/Ubuntu 使用 netplan
        cfg="/etc/netplan/50-cloud-init.yaml"
        if [[ -f "$cfg" ]]; then
            echo -e "${YELLOW}🛠 修改 netplan 配置以启用 IPv6...${RESET}"
            sed -i 's/dhcp4: true/dhcp4: true\ndhcp6: true\naccept-ra: true/' $cfg
            netplan apply
        fi
    elif [[ -f "/etc/network/interfaces" ]]; then
        # ifupdown
        if ! grep -q "inet6 auto" /etc/network/interfaces; then
            echo -e "${YELLOW}🛠 修改 /etc/network/interfaces 以启用 IPv6...${RESET}"
            echo -e "\niface eth0 inet6 auto" >> /etc/network/interfaces
            systemctl restart networking || /etc/init.d/networking restart
        fi
    elif [[ -f "/etc/network/interfaces" && -x "$(command -v rc-service)" ]]; then
        # Alpine
        if ! grep -q "inet6 auto" /etc/network/interfaces; then
            echo -e "${YELLOW}🛠 修改 Alpine 网络配置...${RESET}"
            echo -e "\niface eth0 inet6 auto" >> /etc/network/interfaces
            rc-service networking restart
        fi
    fi

    sleep 3
    pub_ipv6=$(ip -6 addr | grep "scope global" | awk '{print $2}' | cut -d/ -f1)

    if [[ -n "$pub_ipv6" ]]; then
        echo -e "${GREEN}✅ 修复成功，公网 IPv6: $pub_ipv6${RESET}"
    else
        echo -e "${RED}❌ 仍然没有获取到公网 IPv6，可能是服务商没有分配 IPv6${RESET}"
    fi
fi

# 3. 测试 IPv6 连通性
echo -e "${YELLOW}🌐 测试 IPv6 连通性...${RESET}"
if ping6 -c 3 ipv6.google.com >/dev/null 2>&1; then
    echo -e "${GREEN}✅ IPv6 网络正常${RESET}"
else
    echo -e "${RED}❌ 无法连接 IPv6 网络${RESET}"
fi
