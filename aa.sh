#!/bin/bash
# VPS SWAP 管理面板 (完美兼容 Alpine/Debian/Ubuntu/CentOS)

SWAP_FILE="/swapfile"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"
RESET="\033[0m"
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# 获取系统 ID
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    OS_ID="unknown"
fi

# 检查是否为root用户
if [[ $(whoami) != "root" ]]; then
    echo -e "${Error}请以root身份执行该脚本！"
    exit 1
fi

# 返回菜单公共函数
back_to_menu() {
    read -rp "按回车键返回菜单..."
}

# 核心状态获取函数：通过 /proc/meminfo 完美兼容所有 Linux 分支
get_swap_status() {
    if [ ! -f /proc/meminfo ]; then
        STATUS="${RED}未知 (读取失败)${RESET}"
        return
    fi

    # 提取 SwapTotal，单位为 kB
    local swap_total_kb
    swap_total_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)

    if [ -z "$swap_total_kb" ] || [ "$swap_total_kb" -eq 0 ]; then
        STATUS="${RED}未启用${RESET}"
    else
        # 转换为 MB
        local swap_total_mb=$((swap_total_kb / 1024))
        
        if [ "$swap_total_mb" -ge 1000 ]; then
            # 【核心修复：加 51 进位法实现四舍五入保留一位小数】
            # 1024 MB 加上进位常数后，计算出来就会精准显示为 1.0G
            local swap_total_g_int=$(( (swap_total_mb + 51) / 1024 ))
            local swap_total_g_dec=$(( ((swap_total_mb + 51) % 1024) * 10 / 1024 ))
            STATUS="${GREEN}已启用 (${swap_total_g_int}.${swap_total_g_dec}G)${RESET}"
        else
            STATUS="${GREEN}已启用 (${swap_total_mb}M)${RESET}"
        fi
    fi
}




add_swap() {
    echo -ne "${Tip}请输入要添加的 SWAP 大小 (单位G, 默认1): "
    read -r SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-1}

    if [[ ! "$SWAP_SIZE" =~ ^[0-9]+$ ]]; then
        echo -e "${Error}无效的数字输入，操作取消。"
        return 1
    fi

    # 检查并清理旧的 Swap 挂载
    swapoff "$SWAP_FILE" 2>/dev/null || true
    [ -f "$SWAP_FILE" ] && rm -f "$SWAP_FILE"

    echo -e "${Info}正在创建 ${YELLOW}${SWAP_SIZE}G${RESET} 的 Swap 文件，请稍候..."
    
    # 针对 Alpine 的特殊适配，fallocate 在某些文件系统或 Alpine 下不可用，优先用 dd 兜底
    if command -v fallocate >/dev/null 2>&1 && [ "$OS_ID" != "alpine" ]; then
        fallocate -l ${SWAP_SIZE}G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE*1024))
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE*1024))
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    # 写入开机自动挂载
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    echo -e "${Info}SWAP 空间创建成功并已应用！"
}

del_swap() {
    echo -e "${Tip}正在安全卸载并删除 SWAP 文件..."
    swapoff "$SWAP_FILE" 2>/dev/null || true
    
    if [ -f /etc/fstab ]; then
        sed -i "\|$SWAP_FILE|d" /etc/fstab
    fi
    
    if [ -f "$SWAP_FILE" ]; then
        rm -f "$SWAP_FILE"
    fi
    echo -e "${Info}SWAP 空间已彻底删除，配置清理完毕！"
}

view_swap() {
    echo -e "${Info}--- 系统内存与 SWAP 详细状态 ---"
    echo
    # 部分 Alpine 环境下 free 报错，做兜底输出
    free -m 2>/dev/null || cat /proc/meminfo | grep -E "MemTotal|MemFree|SwapTotal|SwapFree"
    echo
    echo -e "${Info}--- 挂载设备信息 ---"
    if swapon --show >/dev/null 2>&1; then
        swapon --show
    else
        cat /proc/swaps
    fi
}

# 主循环面板
while true; do
    clear
    get_swap_status
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}         ◈  VPS SWAP 管理面板  ◈        ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 系统环境  : ${YELLOW}${OS_ID}${RESET}"
    echo -e "${GREEN} SWAP状态  : ${STATUS}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}  1. 添加 SWAP (自定大小)${RESET}"
    echo -e "${GREEN}  2. 删除 SWAP (彻底清理)${RESET}"
    echo -e "${GREEN}  3. 查看系统详细内存状态${RESET}"
    echo -e "${GREEN} ------------------------------------- ${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -ne "${GREEN} 请输入操作编号: ${RESET}"
    
    read -r choice
    
    case "$choice" in
        1)
            add_swap
            back_to_menu
            ;;
        2)
            del_swap
            back_to_menu
            ;;
        3)
            view_swap
            back_to_menu
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${Error}无效选择，请输入正确的数字编号。"
            sleep 1
            ;;
    esac
done
