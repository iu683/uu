#!/bin/bash
#  DNS 管理工具（带有动态状态面板）

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

RESOLV_FILE="/etc/resolv.conf"

# =========================================================
# root 检测
# =========================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

# =========================================================
# 动态获取当前正在生效的 DNS 状态
# =========================================================
get_dns_status() {
    if [ -f "$RESOLV_FILE" ]; then
        # 1. 提取所有合法的 nameserver 地址
        local all_dns=$(awk '$1 == "nameserver" {print $2}' "$RESOLV_FILE")
        
        # 2. 纯 IPv4 提取并合并
        STATUS_IPv4=$(echo "$all_dns" | awk '!/:/ {printf "%s ", $0}' | sed 's/[[:space:]]*$//')
        
        # 3. 纯 IPv6 提取并合并
        STATUS_IPv6=$(echo "$all_dns" | awk '/:/ {printf "%s ", $0}' | sed 's/[[:space:]]*$//')
        
        [ -z "$STATUS_IPv4" ] && STATUS_IPv4="未配置"
        [ -z "$STATUS_IPv6" ] && STATUS_IPv6="未配置"
    else
        STATUS_IPv4="${RED}文件不存在${RESET}"
        STATUS_IPv6="${RED}文件不存在${RESET}"
    fi

    # 4. 检查文件是否被锁定
    if command -v lsattr >/dev/null 2>&1 && [ -f "$RESOLV_FILE" ]; then
        if lsattr "$RESOLV_FILE" 2>/dev/null | head -n 1 | cut -d' ' -f1 | grep -q 'i'; then
            LOCK_STATUS="${RED}已锁定 (🔒)${RESET}"
        else
            LOCK_STATUS="${GREEN}未锁定 (🔓)${RESET}"
        fi
    else
        LOCK_STATUS="不支持检测"
    fi

    # 5. 检查 systemd-resolved 状态
    if systemctl list-unit-files | grep -q "systemd-resolved"; then
        if systemctl is-active --quiet systemd-resolved; then
            RESOLVED_STATUS="${RED}运行中 (可能会覆盖配置)${RESET}"
        else
            RESOLVED_STATUS="${GREEN}已停用${RESET}"
        fi
    else
        RESOLVED_STATUS="未安装"
    fi
}

# =========================================================
# 停用 systemd-resolved
# =========================================================
disable_resolved() {
    if systemctl list-unit-files | grep -q "systemd-resolved"; then
        echo -e "${YELLOW}正在接管系统网络，全面停用 systemd-resolved...${RESET}"
        systemctl disable --now systemd-resolved 2>/dev/null || true
    fi
    # 如果 resolv.conf 是软链接，将其解除
    if [ -L "$RESOLV_FILE" ]; then
        rm -f "$RESOLV_FILE"
    fi
}

# =========================================================
# 设置 resolv.conf DNS
# =========================================================
set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

    # 自动接管并关掉干扰服务
    disable_resolved

    echo -e "${GREEN}正在设置 DNS: $DNS1 $DNS2${RESET}"

    # 解锁文件（如果支持 chattr）
    if command -v chattr >/dev/null 2>&1; then
        chattr -i $RESOLV_FILE 2>/dev/null || true
    fi
    
    rm -f $RESOLV_FILE

    cat > $RESOLV_FILE <<EOF
nameserver $DNS1
EOF

    if [ -n "$DNS2" ]; then
        echo "nameserver $DNS2" >> $RESOLV_FILE
    fi

    cat >> $RESOLV_FILE <<EOF
options timeout:2 attempts:3
EOF

    echo -ne "${GREEN}是否锁定 resolv.conf 防止网络重启被覆盖? (y/n): ${RESET}"
    read -r LOCK
    if [[ "$LOCK" == "y" || "$LOCK" == "Y" ]]; then
        if command -v chattr >/dev/null 2>&1; then
            chattr +i $RESOLV_FILE 2>/dev/null || true
            echo -e "${GREEN}已成功锁定 resolv.conf${RESET}"
        else
            echo -e "${YELLOW}当前系统缺少 chattr 命令，无法锁定文件${RESET}"
        fi
    fi

    echo -e "${GREEN}DNS 配置更新完成！${RESET}"
}

# =========================================================
# 自定义 DNS 输入
# =========================================================
custom_dns() {
    echo -ne "${GREEN}请输入主 DNS: ${RESET}"
    read -r MAIN_DNS
    echo -ne "${GREEN}请输入备用 DNS (可留空): ${RESET}"
    read -r BACKUP_DNS

    if [ -z "$MAIN_DNS" ]; then
        echo -e "${RED}主 DNS 不能为空${RESET}"
        return
    fi

    set_dns_resolvconf "$MAIN_DNS" "$BACKUP_DNS"
}

# =========================================================
# 恢复默认
# =========================================================
restore_default() {
    echo -e "${YELLOW}正在恢复系统默认 DNS...${RESET}"
    if command -v chattr >/dev/null 2>&1; then
        chattr -i $RESOLV_FILE 2>/dev/null || true
    fi
    rm -f $RESOLV_FILE
    echo -e "${GREEN}静态配置已清理。提示：重启 VPS 或重启网络服务后可重新通过 DHCP 获取 DNS${RESET}"
}

# =========================================================
# DNS 视觉面板菜单主逻辑
# =========================================================
dns_menu() {
    while true; do
        # 每次循环动态读取最新状态
        get_dns_status

        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}     ◈     DNS 系统管理面板   ◈       ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} IPv4 DNS   : ${YELLOW}${STATUS_IPv4}${RESET}"
        echo -e "${GREEN} IPv6 DNS   : ${YELLOW}${STATUS_IPv6}${RESET}"
        echo -e "${GREEN} 锁定状态   : ${LOCK_STATUS}"
        echo -e "${GREEN} Resolved   : ${RESOLVED_STATUS}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}  1. Google DNS (8.8.8.8 / 1.1.1.1)${RESET}"
        echo -e "${GREEN}  2. Cloudflare DNS (1.1.1.1 / 1.0.0.1)${RESET}"
        echo -e "${GREEN}  3. 阿里云 DNS (223.5.5.5 / 223.6.6.6)${RESET}"
        echo -e "${GREEN}  4. 腾讯云 DNS (119.29.29.29 / 119.28.28.28)${RESET}"
        echo -e "${GREEN}  5. IPv6 双公网 DNS (CF + Google)${RESET}"
        echo -e "${GREEN}  6. 输入自定义 DNS${RESET}"
        echo -e "${GREEN}  7. 清理静态配置并恢复默认${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        
        read -r choice

        case $choice in
            1) set_dns_resolvconf "8.8.8.8" "1.1.1.1" ;;
            2) set_dns_resolvconf "1.1.1.1" "1.0.0.1" ;;
            3) set_dns_resolvconf "223.5.5.5" "223.6.6.6" ;;
            4) set_dns_resolvconf "119.29.29.29" "119.28.28.28" ;;
            5) set_dns_resolvconf "2606:4700:4700::1111" "2001:4860:4860::8888" ;;
            6) custom_dns ;;
            7) restore_default ;;
            0) break ;;
            *) echo -e "${RED}无效选择，请重新输入...${RESET}"; sleep 1; continue ;;
        esac

        echo -ne "${GREEN}按回车返回面板...${RESET}"
        read -r
    done
}

# 启动菜单
dns_menu
