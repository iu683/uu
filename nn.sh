#!/bin/bash
# VPS SWAP 管理脚本 (兼容 Alpine/Debian/Ubuntu/CentOS)

SWAP_FILE="/swapfile"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 获取系统 ID
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    OS_ID="unknown"
fi

menu() {
    clear
    # 兼容处理：提取 Swap 总量数值
    CUR_SWAP=$(free | awk '/Swap:/ {print $2}')
    
    # 将 KB 转换为人类可读格式
    if [ -z "$CUR_SWAP" ] || [ "$CUR_SWAP" -eq 0 ]; then
        STATUS="未启用"
    else
        # 简单换算成 MB 或 GB
        if [ "$CUR_SWAP" -ge 1048576 ]; then
            STATUS="已启用 ($(echo "scale=2; $CUR_SWAP/1048576" | bc 2>/dev/null || echo "$((CUR_SWAP/1048576))")G)"
        else
            STATUS="已启用 ($((CUR_SWAP/1024))M)"
        fi
    fi

    echo -e "${GREEN}====== VPS SWAP 管理 =========${RESET}"
    echo -e "${GREEN}系统 ID: ${YELLOW}${OS_ID}${RESET}"
    echo -e "${GREEN}当前 SWAP 状态: ${YELLOW}${STATUS}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 添加 SWAP (默认 1G)${RESET}"
    echo -e "${GREEN}2. 删除 SWAP${RESET}"
    echo -e "${GREEN}3. 查看详细状态${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice
    case $choice in
        1) add_swap ;;
        2) del_swap ;;
        3) view_swap ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选项${RESET}"; sleep 1; menu ;;
    esac
}

add_swap() {
    read -p "请输入要添加的 SWAP 大小(单位G, 默认1): " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-1}

    # 检查是否已有 Swap 挂载，先关闭
    swapoff "$SWAP_FILE" 2>/dev/null || true
    [ -f "$SWAP_FILE" ] && rm -f "$SWAP_FILE"

    echo -e "${YELLOW}正在创建 ${SWAP_SIZE}G 的 Swap 文件...${RESET}"
    
    # Alpine 适配：优先使用 dd 保证兼容性
    if command -v fallocate >/dev/null 2>&1 && [ "$OS_ID" != "alpine" ]; then
        fallocate -l ${SWAP_SIZE}G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE*1024))
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE*1024))
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    # 写入开机启动
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    echo -e "${GREEN}✅ 已成功添加 ${SWAP_SIZE}G SWAP${RESET}"
    read -p "按回车返回菜单..." 
    menu
}

del_swap() {
    echo -e "${YELLOW}正在删除 SWAP...${RESET}"
    swapoff "$SWAP_FILE" 2>/dev/null || true
    sed -i "\|$SWAP_FILE|d" /etc/fstab
    [ -f "$SWAP_FILE" ] && rm -f "$SWAP_FILE"
    echo -e "${GREEN}✅ 已彻底删除 SWAP 文件并清理配置${RESET}"
    read -p "按回车返回菜单..." 
    menu
}

view_swap() {
    echo -e "${GREEN}========== 系统 SWAP 详细状态 ==========${RESET}"
    free -m
    # 兼容 Alpine 的 swapon 输出
    if swapon --show >/dev/null 2>&1; then
        swapon --show
    else
        cat /proc/swaps
    fi
    read -p "按回车返回菜单..." 
    menu
}

# 运行脚本
menu
