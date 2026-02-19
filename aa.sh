#!/bin/bash
# 永久 DNS 管理工具（带锁定 + 菜单 + 自定义）

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG_DIR="/etc/systemd/resolved.conf.d"
CONFIG_FILE="$CONFIG_DIR/custom_dns.conf"

########################################
# root 检测
########################################
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

########################################
# 检测 systemd-resolved
########################################
use_resolved=false
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf | grep -q "systemd"; then
        use_resolved=true
    fi
fi

########################################
# 设置 resolved DNS
########################################
set_dns_resolved() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 systemd-resolved 模式${RESET}"

    rm -rf $CONFIG_DIR
    mkdir -p $CONFIG_DIR

    cat > $CONFIG_FILE <<EOF
[Resolve]
DNS=$DNS1
FallbackDNS=$DNS2
EOF

    sed -i '/^DNS=/d' /etc/systemd/resolved.conf 2>/dev/null
    sed -i '/^FallbackDNS=/d' /etc/systemd/resolved.conf 2>/dev/null

    systemctl restart systemd-resolved
    resolvectl flush-caches

    read -p $'\033[32m是否锁定 resolved 配置? (y/n): \033[0m' LOCK
    if [[ "$LOCK" == "y" ]]; then
        chattr +i $CONFIG_FILE 2>/dev/null
        echo -e "${GREEN}已锁定 resolved 配置${RESET}"
    fi

    echo -e "${GREEN}DNS 已更新完成${RESET}"
}

########################################
# 设置 resolv.conf DNS
########################################
set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}使用 resolv.conf 模式${RESET}"

    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<EOF
nameserver $DNS1
nameserver $DNS2
options timeout:2 attempts:3
EOF

    read -p $'\033[32m是否锁定 resolv.conf? (y/n): \033[0m' LOCK
    if [[ "$LOCK" == "y" ]]; then
        chattr +i /etc/resolv.conf 2>/dev/null
        echo -e "${GREEN}已锁定 resolv.conf${RESET}"
    fi

    echo -e "${GREEN}DNS 已更新完成${RESET}"
}

########################################
# 恢复默认
########################################
restore_default() {

    echo -e "${YELLOW}恢复系统默认 DNS...${RESET}"

    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    rm -rf $CONFIG_DIR

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved
        echo -e "${GREEN}已恢复 systemd-resolved 默认${RESET}"
    else
        echo -e "${GREEN}已删除手动 DNS，请重启网络${RESET}"
    fi
}

########################################
# 查看当前 DNS
########################################
show_dns() {
    echo
    echo -e "${GREEN}===== 当前 DNS 状态 =====${RESET}"

    if $use_resolved; then
        resolvectl status | grep -E "DNS Servers|Fallback DNS Servers"
    fi

    echo
    cat /etc/resolv.conf 2>/dev/null
    echo
}

########################################
# 自定义 DNS
########################################
custom_dns() {
    read -p $'\033[32m请输入主 DNS: \033[0m' MAIN_DNS
    read -p $'\033[32m请输入备用 DNS (可留空，多个空格分隔): \033[0m' BACKUP_DNS

    if [[ -z "$MAIN_DNS" ]]; then
        echo -e "${RED}主 DNS 不能为空${RESET}"
        return
    fi

    $use_resolved && set_dns_resolved "$MAIN_DNS" "$BACKUP_DNS" || set_dns_resolvconf "$MAIN_DNS" "$BACKUP_DNS"
}

########################################
# 菜单
########################################
menu() {
    clear
    echo -e "${GREEN}=== DNS 永久管理工具 ===${RESET}"
    echo -e "${GREEN}1) Google DNS (8.8.8.8 / 1.1.1.1)${RESET}"
    echo -e "${GREEN}2) Cloudflare DNS (1.1.1.1 / 1.0.0.1)${RESET}"
    echo -e "${GREEN}3) 阿里 DNS (223.5.5.5 / 223.6.6.6)${RESET}"
    echo -e "${GREEN}4) claw (100.100.2.136 / 100.100.2.138)${RESET}"
    echo -e "${GREEN}5) 自定义 DNS${RESET}"
    echo -e "${GREEN}6) 恢复系统默认${RESET}"
    echo -e "${GREEN}7) 查看当前 DNS${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p $'\033[32m请选择: \033[0m' choice

    case $choice in
        1) $use_resolved && set_dns_resolved 8.8.8.8 1.1.1.1 || set_dns_resolvconf 8.8.8.8 1.1.1.1 ;;
        2) $use_resolved && set_dns_resolved 1.1.1.1 1.0.0.1 || set_dns_resolvconf 1.1.1.1 1.0.0.1 ;;
        3) $use_resolved && set_dns_resolved 223.5.5.5 223.6.6.6 || set_dns_resolvconf 223.5.5.5 223.6.6.6 ;;
        4) $use_resolved && set_dns_resolved 100.100.2.136 100.100.2.138 || set_dns_resolvconf 100.100.2.136 100.100.2.138 ;;
        5) custom_dns ;;
        6) restore_default ;;
        7) show_dns ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac

    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

menu
