#!/bin/bash
# ==============================================
# VPS /64 IPv6 临时测试配置脚本
# 自动检测网卡并配置 IPv6
# ==============================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# 自动检测主网卡（非 loopback、非 docker）
detect_nic() {
    NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker' | head -n1)
    if [ -z "$NIC" ]; then
        echo -e "${RED}❌ 未检测到网卡，请手动输入网卡名称:${RESET}"
        read -r NIC
    fi
    echo -e "${GREEN}✅ 检测到主网卡: $NIC${RESET}"
}

# 添加 IPv6 地址
add_ipv6() {
    read -p "请输入要添加的 IPv6 地址（带前缀，如 /64）: " IPV6
    sudo ip -6 addr add $IPV6 dev $NIC 2>/dev/null || echo -e "${RED}⚠️ IPv6 地址已存在或添加失败${RESET}"
}

# 添加默认路由
add_route() {
    # 尝试直接 dev
    sudo ip -6 route add default dev $NIC 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}⚠️ 直接通过网卡添加默认路由失败，可能需要 VPS 面板网关或 NDP 代理${RESET}"
    else
        echo -e "${GREEN}✅ IPv6 默认路由已添加（dev $NIC）${RESET}"
    fi
}

# 测试 IPv6 连通性
test_ipv6() {
    echo -e "${GREEN}测试 IPv6 是否可用:${RESET}"
    ping6 -c 3 ipv6.google.com 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ IPv6 不可达，可能需要 VPS 面板提供的网关或 NDP 配置${RESET}"
    else
        echo -e "${GREEN}✅ IPv6 可达${RESET}"
    fi
}

# 主流程
echo -e "${GREEN}=== VPS /64 IPv6 临时配置脚本 ===${RESET}"
detect_nic
add_ipv6
add_route
test_ipv6

echo -e "${GREEN}🔄 配置完成，临时生效，重启后失效${RESET}"
