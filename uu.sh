#!/bin/sh
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

RESOLV_FILE="/etc/resolv.conf"

# =========================================================
# root 检测 (Alpine 标准 sh 兼容语法)
# =========================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

# =========================================================
# 动态获取当前正在生效的 DNS 状态
# =========================================================
get_dns_status() {
    # 检查 resolv.conf 是否存在
    if [ -f "$RESOLV_FILE" ]; then
        # 提取 nameserver，并将多行连接为单行显示
        local dns_list=$(grep -E '^\s*nameserver' "$RESOLV_FILE" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
        STATUS_DNS=${dns_list:-"未配置 DNS"}
    else
        STATUS_DNS="${RED}文件不存在${RESET}"
    fi

    # 检查文件是否被锁定 (Alpine 经典 lsattr 属性检测)
    if command -v lsattr >/dev/null 2>&1 && [ -f "$RESOLV_FILE" ]; then
        if lsattr "$RESOLV_FILE" 2>/dev/null | head -n 1 | cut -d' ' -f1 | grep -q 'i'; then
            LOCK_STATUS="${RED}已锁定 (🔒)${RESET}"
        else
            LOCK_STATUS="${GREEN}未锁定 (🔓)${RESET}"
        fi
    else
        LOCK_STATUS="不支持检测"
    fi
}

# =========================================================
# 设置 resolv.conf DNS
# =========================================================
set_dns_resolvconf() {
    DNS1=$1
    DNS2=$2

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
    read -r LOCK </dev/tty
    if [ "$LOCK" = "y" ] || [ "$LOCK" = "Y" ]; then
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
    read -r MAIN_DNS </dev/tty
    echo -ne "${GREEN}请输入备用 DNS (可留空): ${RESET}"
    read -r BACKUP_DNS </dev/tty

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
    # Alpine 可以通过重启网络触发 udhcpc 自动重新获取 DNS
    echo -e "${GREEN}静态 DNS 已清理。提示：在 Alpine 下可执行 'rc-service networking restart' 重新获取 DHCP DNS${RESET}"
}

# =========================================================
# DNS 视觉面板菜单
# =========================================================
dns_menu() {
    while true; do
        # 每次循环动态读取最新 DNS 状态
        get_dns_status

        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}   ◈    DNS 系统管理面板   ◈   ${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} 当前 DNS : ${YELLOW}${STATUS_DNS}${RESET}"
        echo -e "${GREEN} 锁定状态 : ${LOCK_STATUS}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}  1. Google DNS (8.8.8.8)${RESET}"
        echo -e "${GREEN}  2. Cloudflare DNS (1.1.1.1)${RESET}"
        echo -e "${GREEN}  3. 阿里云 DNS (223.5.5.5)${RESET}"
        echo -e "${GREEN}  4. 腾讯云 DNS (119.29.29.29)${RESET}"
        echo -e "${GREEN}  5. IPv6 双公网 DNS${RESET}"
        echo -e "${GREEN}  6. 手动输入自定义 DNS${RESET}"
        echo -e "${GREEN}  7. 清理静态配置并恢复默认${RESET}"
        echo -e "${GREEN}  0. 退出管理面板${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        
        read -r choice </dev/tty

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
        read -r </dev/tty
    done
}

# =========================================================
# 执行主逻辑
# =========================================================
dns_menu
