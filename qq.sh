#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检测 systemd-resolved
use_resolved=false
if systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        use_resolved=true
    fi
fi

########################################
# 清理并设置 systemd-resolved DNS
########################################
set_dns_resolved() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 systemd-resolved 模式${RESET}"

    # 清理旧 drop-in
    sudo rm -rf /etc/systemd/resolved.conf.d
    sudo mkdir -p /etc/systemd/resolved.conf.d

    # 清理主配置 DNS 行
    sudo sed -i '/^DNS=/d' /etc/systemd/resolved.conf 2>/dev/null
    sudo sed -i '/^FallbackDNS=/d' /etc/systemd/resolved.conf 2>/dev/null

    # 写入新配置
    sudo tee /etc/systemd/resolved.conf.d/custom_dns.conf > /dev/null <<EOF
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=8.8.4.4 1.0.0.1
EOF

    sudo systemctl restart systemd-resolved

    echo -e "${GREEN}DNS 已强制覆盖完成${RESET}"
}

########################################
# 清理并设置 resolv.conf DNS
########################################
set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 resolv.conf 模式${RESET}"

    sudo chattr -i /etc/resolv.conf 2>/dev/null

    # 如果是符号链接，删除
    if [ -L /etc/resolv.conf ]; then
        sudo rm -f /etc/resolv.conf
    fi

    # 删除旧文件
    sudo rm -f /etc/resolv.conf

    # 写入新 DNS
    sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver $DNS1
nameserver $DNS2
EOF

    sudo chattr +i /etc/resolv.conf 2>/dev/null

    echo -e "${GREEN}DNS 已强制覆盖并锁定${RESET}"
}

########################################
# 恢复系统默认 DNS
########################################
restore_default() {

    echo -e "${YELLOW}恢复系统默认 DNS...${RESET}"

    sudo chattr -i /etc/resolv.conf 2>/dev/null
    sudo rm -f /etc/resolv.conf

    if $use_resolved; then
        sudo rm -rf /etc/systemd/resolved.conf.d
        sudo systemctl restart systemd-resolved
        echo -e "${GREEN}已恢复 systemd-resolved 默认设置${RESET}"
    else
        echo -e "${GREEN}已删除手动 DNS，请重启网络服务${RESET}"
    fi
}

########################################
# 查看当前 DNS
########################################
show_dns() {
    echo
    echo -e "${GREEN}===== 当前 DNS 状态 =====${RESET}"

    if $use_resolved; then
        echo -e "${YELLOW}systemd-resolved 状态:${RESET}"
        resolvectl status | grep -E "DNS Servers|Fallback DNS Servers"
    fi

    echo -e "${YELLOW}/etc/resolv.conf 内容:${RESET}"
    cat /etc/resolv.conf 2>/dev/null
    echo
}

########################################
# 菜单
########################################
menu() {
    clear
    echo -e "${GREEN}===  DNS 管理工具 ===${RESET}"
    echo -e "${GREEN}1) Google DNS (8.8.8.8 / 1.1.1.1)${RESET}"
    echo -e "${GREEN}2) 阿里云 DNS (223.5.5.5 / 183.60.83.19)${RESET}"
    echo -e "${GREEN}3) ClawDNS (100.100.2.136 / 100.100.2.138)${RESET}"
    echo -e "${GREEN}4) 查看当前 DNS${RESET}"
    echo -e "${GREEN}5) 恢复系统默认${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p $'\033[32m请选择: \033[0m' choice

    case $choice in
        1)
            $use_resolved && set_dns_resolved 8.8.8.8 1.1.1.1 || set_dns_resolvconf 8.8.8.8 1.1.1.1
            ;;
        2)
            $use_resolved && set_dns_resolved 223.5.5.5 183.60.83.19 || set_dns_resolvconf 223.5.5.5 183.60.83.19
            ;;
        3)
            $use_resolved && set_dns_resolved 100.100.2.136 100.100.2.138 || set_dns_resolvconf 100.100.2.136 100.100.2.138
            ;;
        4)
            show_dns
            ;;
        5)
            restore_default
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            ;;
    esac

    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu
