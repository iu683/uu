#!/bin/bash
# DNS 管理工具（兼容 Alpine/Debian/Ubuntu/CentOS）

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

RESOLV_FILE="/etc/resolv.conf"

# 环境初始化与系统检测
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="linux"
fi

prepare_deps() {
    if [[ "$OS" == "alpine" ]]; then
        if ! command -v chattr >/dev/null 2>&1; then
            echo -e "${YELLOW}正在为 Alpine 安装 e2fsprogs-extra...${RESET}"
            apk add --no-cache e2fsprogs-extra
        fi
    fi
}

disable_resolved() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "systemd-resolved"; then
            echo -e "${YELLOW}检测到 systemd-resolved，正在停用...${RESET}"
            systemctl disable --now systemd-resolved 2>/dev/null
        fi
    fi
    [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE"
}

set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2
    prepare_deps
    disable_resolved
    echo -e "${GREEN}正在设置 DNS: $DNS1 $DNS2${RESET}"
    chattr -i $RESOLV_FILE 2>/dev/null
    rm -f $RESOLV_FILE
    cat > $RESOLV_FILE <<EOF
nameserver $DNS1
nameserver $DNS2
options timeout:2 attempts:3
EOF
    read -p "是否锁定 resolv.conf 防止被系统修改? (y/n): " LOCK
    if [[ "$LOCK" == "y" ]]; then
        chattr +i $RESOLV_FILE 2>/dev/null
        echo -e "${GREEN}已通过 chattr 锁定 resolv.conf${RESET}"
    fi
    echo -e "${GREEN}DNS 更新完成${RESET}"
}

custom_dns() {
    read -p "请输入主 DNS: " MAIN_DNS
    read -p "请输入备用 DNS: " BACKUP_DNS
    # 修正后的逻辑
    if [[ -z "$MAIN_DNS" ]]; then
        echo -e "${RED}主 DNS 不能为空${RESET}"
        return
    fi
    set_dns_resolvconf "$MAIN_DNS" "$BACKUP_DNS"
}

restore_default() {
    echo -e "${YELLOW}恢复系统默认 DNS...${RESET}"
    chattr -i $RESOLV_FILE 2>/dev/null
    rm -f $RESOLV_FILE
    echo -e "${GREEN}已解锁并删除静态配置${RESET}"
}

show_dns() {
    echo -e "\n${GREEN}===== 当前 DNS 状态 =====${RESET}"
    [ -f "$RESOLV_FILE" ] && cat $RESOLV_FILE || echo "文件不存在"
    echo
}

menu() {
    clear
    echo -e "${GREEN}=== DNS 管理工具  ===${RESET}"
    echo "${GREEN}1) Google DNS (8.8.8.8)${RESET}"
    echo "${GREEN}2) Cloudflare DNS (1.1.1.1)${RESET}"
    echo "${GREEN}3) 阿里云 DNS (223.5.5.5)${RESET}"
    echo "${GREEN}4) 腾讯云 DNS (119.29.29.29)${RESET}"
    echo "${GREEN}5) Claw 专用 DNS (100.100.2.136)${RESET}"
    echo "${GREEN}6) IPv6 DNS (CF+Google)${RESET}"
    echo "${GREEN}7) 自定义 DNS${RESET}"
    echo "${GREEN}8) 恢复默认/解锁文件${RESET}"
    echo "${GREEN}9) 查看当前 DNS${RESET}"
    echo "${GREEN}0) 退出${RESET}"
    read -p $'\033[32m请选择: \033[0m' choice
    case $choice in
        1) set_dns_resolvconf 8.8.8.8 8.8.4.4 ;;
        2) set_dns_resolvconf 1.1.1.1 1.0.0.1 ;;
        3) set_dns_resolvconf 223.5.5.5 223.6.6.6 ;;
        4) set_dns_resolvconf 119.29.29.29 119.28.28.28 ;;
        5) set_dns_resolvconf 100.100.2.136 100.100.2.138 ;;
        6) set_dns_resolvconf 2606:4700:4700::1111 2001:4860:4860::8888 ;;
        7) custom_dns ;;
        8) restore_default ;;
        9) show_dns ;;
        0) exit 0 ;;
    esac
    read -p "按回车返回菜单..."
    menu
}

menu
