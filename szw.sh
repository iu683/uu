#!/bin/bash
# =============================================
# 简化版 IPv4/IPv6 配置菜单
# 只需输入 IP 地址，掩码和网关自动设置
# 支持 Debian / Ubuntu (netplan/interfaces) + Alpine
# =============================================

GREEN="\033[32m"
RESET="\033[0m"

# 自动检测默认网卡
detect_nic() {
    NIC=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$NIC" ]; then
        echo -e "${GREEN}请输入网卡名称:${RESET}"
        read -r NIC
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -d /etc/netplan ]; then
        OS="ubuntu_netplan"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        echo -e "${GREEN}❌ 不支持的系统${RESET}"
        exit 1
    fi
}

# 临时配置
temp_config() {
    ip addr flush dev $NIC
    if [ "$CONFIG_V4" = true ]; then
        ip addr add $IPV4/24 dev $NIC
        # 网关自动取 IP 同网段 +1
        GW4=$(echo $IPV4 | awk -F. '{print $1"."$2"."$3".1"}')
        ip route add default via $GW4
        echo -e "${GREEN}✅ IPv4 临时配置完成${RESET}"
    fi
    if [ "$CONFIG_V6" = true ]; then
        ip -6 addr add $IPV6/64 dev $NIC
        # IPv6 网关自动取 ::1
        GW6=$(echo $IPV6 | sed 's/::[0-9]*$/::1/')
        ip -6 route add default via $GW6
        echo -e "${GREEN}✅ IPv6 临时配置完成${RESET}"
    fi
}

# 永久配置
permanent_config() {
    if [ "$OS" = "debian" ]; then
        FILE="/etc/network/interfaces"
        echo "auto $NIC" > $FILE
        if [ "$CONFIG_V4" = true ]; then
            GW4=$(echo $IPV4 | awk -F. '{print $1"."$2"."$3".1"}')
            cat >> $FILE <<EOF
iface $NIC inet static
    address $IPV4
    netmask 255.255.255.0
    gateway $GW4
EOF
        fi
        if [ "$CONFIG_V6" = true ]; then
            GW6=$(echo $IPV6 | sed 's/::[0-9]*$/::1/')
            cat >> $FILE <<EOF
iface $NIC inet6 static
    address $IPV6
    netmask 64
    gateway $GW6
EOF
        fi
        systemctl restart networking
    elif [ "$OS" = "ubuntu_netplan" ]; then
        FILE="/etc/netplan/01-netcfg.yaml"
        echo "network:
  version: 2
  renderer: networkd
  ethernets:
    $NIC:" > $FILE
        if [ "$CONFIG_V4" = true ]; then
            GW4=$(echo $IPV4 | awk -F. '{print $1"."$2"."$3".1"}')
            cat >> $FILE <<EOF
      addresses: [$IPV4/24]
      gateway4: $GW4
      nameservers:
        addresses: [8.8.8.8,8.8.4.4]
EOF
        fi
        if [ "$CONFIG_V6" = true ]; then
            GW6=$(echo $IPV6 | sed 's/::[0-9]*$/::1/')
            cat >> $FILE <<EOF
      addresses: [$IPV6/64]
      gateway6: $GW6
      nameservers:
        addresses: [2001:4860:4860::8888,2001:4860:4860::8844]
EOF
        fi
        netplan apply
    elif [ "$OS" = "alpine" ]; then
        FILE="/etc/network/interfaces"
        echo "auto $NIC" > $FILE
        if [ "$CONFIG_V4" = true ]; then
            GW4=$(echo $IPV4 | awk -F. '{print $1"."$2"."$3".1"}')
            cat >> $FILE <<EOF
iface $NIC inet static
    address $IPV4
    netmask 255.255.255.0
    gateway $GW4
EOF
        fi
        if [ "$CONFIG_V6" = true ]; then
            GW6=$(echo $IPV6 | sed 's/::[0-9]*$/::1/')
            cat >> $FILE <<EOF
iface $NIC inet6 static
    address $IPV6
    netmask 64
    gateway $GW6
EOF
        fi
        /etc/init.d/networking restart
    fi
    echo -e "${GREEN}🎉 永久配置完成${RESET}"
}

# 网络状态检测
check_network() {
    echo -e "${GREEN}当前网络状态:${RESET}"
    if [ "$CONFIG_V4" = true ]; then
        ping -c 2 8.8.8.8 &>/dev/null && echo -e "${GREEN}IPv4: 连通${RESET}" || echo -e "${GREEN}IPv4: 不连通${RESET}"
    fi
    if [ "$CONFIG_V6" = true ]; then
        ping6 -c 2 ipv6.google.com &>/dev/null && echo -e "${GREEN}IPv6: 连通${RESET}" || echo -e "${GREEN}IPv6: 不连通${RESET}"
    fi
}

# 菜单
menu() {
    while true; do
        echo -e "${GREEN}========================================${RESET}"
        echo -e "${GREEN}      IPv4/IPv6 配置菜单 (只输入 IP)     ${RESET}"
        echo -e "${GREEN}1) 配置 IPv4${RESET}"
        echo -e "${GREEN}2) 配置 IPv6${RESET}"
        echo -e "${GREEN}3) 配置 IPv4 + IPv6${RESET}"
        echo -e "${GREEN}4) 退出${RESET}"
        echo -e "${GREEN}========================================${RESET}"
        read -p "请输入选项 [1-4]: " choice
        case "$choice" in
            1)
                CONFIG_V4=true
                CONFIG_V6=false
                read -p "请输入 IPv4 地址: " IPV4
                ;;
            2)
                CONFIG_V4=false
                CONFIG_V6=true
                read -p "请输入 IPv6 地址: " IPV6
                ;;
            3)
                CONFIG_V4=true
                CONFIG_V6=true
                read -p "请输入 IPv4 地址: " IPV4
                read -p "请输入 IPv6 地址: " IPV6
                ;;
            4)
                exit 0
                ;;
            *)
                echo -e "${GREEN}❌ 无效选项${RESET}"
                continue
                ;;
        esac

        detect_nic
        detect_os
        temp_config
        permanent_config
        check_network

        echo -e "${GREEN}🔄 配置完成，按回车返回菜单${RESET}"
        read -r
    done
}

# 启动菜单
menu
