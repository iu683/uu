#!/bin/bash
# ========================================
# PVE 容器(CT) 一键管理脚本（国内/国外自动判断）
# Author: oneclickvirt 改
# ========================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

# 自动判断国内外源
check_source() {
    if ping -c 1 -W 1 google.com >/dev/null 2>&1; then
        echo "github"
    else
        echo "cdn"
    fi
}

# 下载脚本函数
download_scripts() {
    SOURCE=$(check_source)
    if [ "$SOURCE" = "github" ]; then
        BASE_URL="https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts"
        echo -e "${GREEN}检测到国外环境，使用 GitHub 源下载${RESET}"
    else
        BASE_URL="https://cdn.spiritlhl.net/https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts"
        echo -e "${GREEN}检测到国内环境，使用 CDN 源下载${RESET}"
    fi

    if [ ! -f buildct.sh ]; then
        echo -e "${YELLOW}未找到 buildct.sh，正在下载...${RESET}"
        curl -L ${BASE_URL}/buildct.sh -o buildct.sh && chmod +x buildct.sh
    fi

    if [ ! -f pve_delete.sh ]; then
        echo -e "${YELLOW}未找到 pve_delete.sh，正在下载...${RESET}"
        curl -L ${BASE_URL}/pve_delete.sh -o pve_delete.sh && chmod +x pve_delete.sh
    fi
}

# 开设容器
create_ct() {
    echo -e "${CYAN}请输入开设容器所需参数:${RESET}"
    read -p "CTID(100~256): " CTID
    read -p "密码(英文数字组合): " PASSWORD
    read -p "CPU核数: " CPU
    read -p "内存(MB): " MEM
    read -p "硬盘(GB): " DISK
    read -p "SSH端口: " SSHPORT
    read -p "80端口: " PORT80
    read -p "443端口: " PORT443
    read -p "外网端口起: " STARTPORT
    read -p "外网端口止: " ENDPORT
    read -p "系统(如 debian11 ubuntu20): " OS
    read -p "存储盘(如 local): " STORAGE
    read -p "独立IPV6(默认N): " IPV6

    ./buildct.sh $CTID $PASSWORD $CPU $MEM $DISK $SSHPORT ${PORT80:-0} ${PORT443:-0} $STARTPORT $ENDPORT $OS $STORAGE ${IPV6:-N}
}

# 删除指定容器
delete_ct() {
    read -p "请输入要删除的 CTID (可输入多个, 空格分隔): " CTIDS
    ./pve_delete.sh $CTIDS
}

# 查看容器信息
check_ct() {
    read -p "请输入要查看的 CTID: " CTID
    if [ -f ct${CTID} ]; then
        cat ct${CTID}
    else
        echo -e "${RED}未找到 CTID ${CTID} 的信息文件${RESET}"
    fi
}

# 删除所有容器
delete_all_cts() {
    echo -e "${RED}⚠️ 警告：此操作将删除所有容器、清空 IPv4/IPv6 NAT 规则并重置网络！${RESET}"
    read -p "确认执行？(yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${YELLOW}正在删除所有容器...${RESET}"
        pct list | awk 'NR>1{print $1}' | xargs -I {} sh -c 'pct stop {}; pct destroy {}'

        echo -e "${YELLOW}清理容器信息文件...${RESET}"
        rm -rf ct*

        echo -e "${YELLOW}清空防火墙规则...${RESET}"
        iptables -t nat -F
        iptables -t filter -F
        ip6tables -t nat -F
        ip6tables -t filter -F
        rm -rf /usr/local/bin/ipv6_nat_rules.sh

        echo -e "${YELLOW}重启网络服务...${RESET}"
        service networking restart
        systemctl restart networking.service
        systemctl restart ndpresponder.service

        echo -e "${YELLOW}保存 iptables 配置...${RESET}"
        iptables-save | awk '{if($1=="COMMIT"){delete x}}$1=="-A"?!x[$0]++:1' | iptables-restore
        iptables-save > /etc/iptables/rules.v4

        echo -e "${GREEN}✅ 所有容器和端口映射已删除，网络已重置${RESET}"
    else
        echo -e "${GREEN}已取消操作${RESET}"
    fi
}


# 主菜单
menu() {
    clear
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}      PVE容器 LXC 管理菜单               ${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}1) 开设容器${RESET}"
    echo -e "${GREEN}2) 删除指定容器${RESET}"
    echo -e "${GREEN}3) 查看容器信息${RESET}"
    echo -e "${GREEN}4) 删除所有容器${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    case $choice in
        1) create_ct ;;
        2) delete_ct ;;
        3) check_ct ;;
        4) delete_all_cts ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
    esac
    echo -e "${YELLOW}按任意键返回菜单...${RESET}"
    read -n 1
    menu
}

# 运行
download_scripts
menu
