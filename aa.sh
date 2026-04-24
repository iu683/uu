#!/bin/bash
# ========================================
# NextTrace 管理
# 支持移动 / 联通 / 电信 单独或一键全测
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 节点配置：名称 IP
NODES=(
    "移动 120.233.18.250"
    "联通 157.148.58.29"
    "电信 14.116.225.60"
)

# ==============================
# 检查 NextTrace 是否安装
# ==============================
check_install() {
    if ! command -v nexttrace >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 NextTrace...${RESET}"
        curl -fsSL nxtrace.org/nt | bash >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}NextTrace 安装失败，请检查网络或手动安装${RESET}"
            exit 1
        fi
    fi
}

# ==============================
# 执行单项测试逻辑
# ==============================
do_trace() {
    local provider=$1
    local ip=$2
    
    echo -e "\n${YELLOW}>>> 正在测试: ${provider} (${ip})${RESET}"
    
    # 执行大包并提取路径（去重处理）
    route_big=$(nexttrace --tcp --psize 1024 "$ip" -p 80 2>/dev/null | awk '/Hop/ {print $0}')
    # 执行小包
    route_small=$(nexttrace --tcp --psize 12 "$ip" -p 80 2>/dev/null | awk '/Hop/ {print $0}')

    if [ -z "$route_big" ]; then
        echo -e "${RED}[错误] 无法获取路由数据，请检查网络${RESET}"
        return
    fi

    # 对比结果
    diff_output=$(diff <(echo "$route_big") <(echo "$route_small"))
    if [ -z "$diff_output" ]; then
        echo -e "${GREEN}[结果] 大小包路由一致 ✅${RESET}"
    else
        echo -e "${RED}[结果] 发现路由差异❌${RESET}"
        echo "$diff_output"
    fi
}

# ==============================
# 菜单函数
# ==============================
show_menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}      大小包测试      ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1) 移动${RESET}"
    echo -e "${GREEN}2) 联通${RESET}"
    echo -e "${GREEN}3) 电信${RESET}"
    echo -e "${GREEN}4) 一键测试三网${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    read -rp $'\033[32m请选择测试节点: \033[0m' choice

    case $choice in
        1) do_trace "移动" "120.233.18.250" ;;
        2) do_trace "联通" "157.148.58.29" ;;
        3) do_trace "电信" "14.116.225.60" ;;
        4)
            for node in "${NODES[@]}"; do
                do_trace $node
                echo -e "${YELLOW}------------------------------${RESET}"
            done
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}" ;;
    esac
    
    read -rp $'\n\033[33m按回车返回菜单...\033[0m'
}

# 主程序
check_install
while true; do
    show_menu
done
