#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# 判断是否使用 systemd-resolved（Ubuntu 默认）
use_resolved=false
if systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        use_resolved=true
    fi
fi

set_dns_resolved() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 systemd-resolved 模式${RESET}"

    sudo mkdir -p /etc/systemd
    sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak 2>/dev/null

    sudo tee /etc/systemd/resolved.conf > /dev/null <<EOF
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=8.8.4.4 1.0.0.1
EOF

    sudo systemctl restart systemd-resolved

    echo -e "${GREEN}修改完成！${RESET}"
}

set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 resolv.conf 模式（Debian / VPS）${RESET}"

    sudo chattr -i /etc/resolv.conf 2>/dev/null
    sudo cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

    sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver $DNS1
nameserver $DNS2
EOF

    sudo chattr +i /etc/resolv.conf 2>/dev/null

    echo -e "${GREEN}修改完成并已锁定！${RESET}"
}

menu() {
    clear
    echo -e "${GREEN}=== DNS 自动切换工具 ===${RESET}"
    echo -e "${GREEN}1) Google DNS (8.8.8.8 / 1.1.1.1)${RESET}"
    echo -e "${GREEN}2) 阿里云 DNS (223.5.5.5 / 183.60.83.19)${RESET}"
    echo -e "${GREEN}3) ClawDNS (100.100.2.136 / 100.100.2.138)${RESET}"
    echo -e "${GREEN}4) 查看当前 DNS${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择: \033[0m' choice

    case $choice in
        1)
            if $use_resolved; then
                set_dns_resolved 8.8.8.8 1.1.1.1
            else
                set_dns_resolvconf 8.8.8.8 1.1.1.1
            fi
            ;;
        2)
            if $use_resolved; then
                set_dns_resolved 223.5.5.5 183.60.83.19
            else
                set_dns_resolvconf 223.5.5.5 183.60.83.19
            fi
            ;;
        3)
            if $use_resolved; then
                set_dns_resolved 100.100.2.136 100.100.2.138
            else
                set_dns_resolvconf 100.100.2.136 100.100.2.138
            fi
            ;;
        4)
            echo
            echo -e "${GREEN}当前 DNS:${RESET}"
            if $use_resolved; then
                resolvectl status | grep "DNS Servers" -A2
            fi
            cat /etc/resolv.conf
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            ;;
    esac

    echo
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu
