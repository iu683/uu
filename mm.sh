#!/bin/bash
# Ubuntu 静态 DNS 管理工具（关闭 systemd-resolved + resolv.conf）

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

RESOLV_FILE="/etc/resolv.conf"

########################################
# root 检测
########################################
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

########################################
# 停用 systemd-resolved
########################################
disable_resolved() {
    systemctl disable --now systemd-resolved 2>/dev/null
    # 删除 stub-resolv.conf 链接
    [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE"
}

########################################
# 设置 resolv.conf DNS
########################################
set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

    echo -e "${GREEN}正在设置 DNS: $DNS1 $DNS2${RESET}"

    chattr -i $RESOLV_FILE 2>/dev/null
    rm -f $RESOLV_FILE

    cat > $RESOLV_FILE <<EOF
nameserver $DNS1
nameserver $DNS2
options timeout:2 attempts:3
EOF

    read -p $'\033[32m是否锁定 resolv.conf? (y/n): \033[0m' LOCK
    if [[ "$LOCK" == "y" ]]; then
        chattr +i $RESOLV_FILE 2>/dev/null
        echo -e "${GREEN}已锁定 resolv.conf${RESET}"
    fi

    echo -e "${GREEN}DNS 已更新完成${RESET}"
}

########################################
# 自定义 DNS
########################################
custom_dns() {
    read -p $'\033[32m请输入主 DNS: \033[0m' MAIN_DNS
    read -p $'\033[32m请输入备用 DNS (可留空): \033[0m' BACKUP_DNS

    if [[ -z "$MAIN_DNS" ]]; then
        echo -e "${RED}主 DNS 不能为空${RESET}"
        return
    fi

    set_dns_resolvconf "$MAIN_DNS" "$BACKUP_DNS"
}

########################################
# 恢复默认
########################################
restore_default() {
    echo -e "${YELLOW}恢复系统默认 DNS...${RESET}"
    chattr -i $RESOLV_FILE 2>/dev/null
    rm -f $RESOLV_FILE
    echo -e "${GREEN}已删除静态 DNS，请重启网络或配置新的 DNS${RESET}"
}

########################################
# 查看当前 DNS
########################################
show_dns() {
    echo
    echo -e "${GREEN}===== 当前 DNS 状态 =====${RESET}"
    cat $RESOLV_FILE 2>/dev/null
    echo
}

########################################
# 菜单
########################################
menu() {
    disable_resolved  # 每次进入菜单确保 systemd-resolved 被停用

    clear
    echo -e "${GREEN}=== Ubuntu 静态 DNS 管理工具 ===${RESET}"
    echo -e "${GREEN}1) Google DNS (8.8.8.8 / 1.1.1.1)${RESET}"
    echo -e "${GREEN}2) Cloudflare DNS (1.1.1.1 / 1.0.0.1)${RESET}"
    echo -e "${GREEN}3) 阿里 DNS (223.5.5.5 / 223.6.6.6)${RESET}"
    echo -e "${GREEN}4) claw (100.100.2.136 / 100.100.2.138)${RESET}"
    echo -e "${GREEN}5) 自定义 DNS${RESET}"
    echo -e "${GREEN}6) 恢复默认${RESET}"
    echo -e "${GREEN}7) 查看当前 DNS${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p $'\033[32m请选择: \033[0m' choice

    case $choice in
        1) set_dns_resolvconf 8.8.8.8 1.1.1.1 ;;
        2) set_dns_resolvconf 1.1.1.1 1.0.0.1 ;;
        3) set_dns_resolvconf 223.5.5.5 223.6.6.6 ;;
        4) set_dns_resolvconf 100.100.2.136 100.100.2.138 ;;
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
