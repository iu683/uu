#!/bin/bash
# ========================================
# NextTrace 一键管理脚本（菜单版）
# 首次运行自动安装
# 支持移动 / 联通 / 电信大小包测试
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ==============================
# 检查 NextTrace 是否安装
# ==============================
check_install() {
    if ! command -v nexttrace >/dev/null 2>&1; then
        # 静默安装 NextTrace
        curl -fsSL nxtrace.org/nt | bash >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}NextTrace 安装失败，请检查网络或手动安装${RESET}"
            exit 1
        fi
    fi
}

# ==============================
# 执行测试
# 参数: $1=节点名称, $2=IP
# ==============================
run_test() {
    local provider=$1
    local ip=$2
    echo -e "\n${YELLOW}=== 测试 ${provider} ===${RESET}"

    echo "大包测试（1024K）："
    route_big=$(nexttrace --tcp --psize 1024 "$ip" -p 80 | awk '/Hop/ {print $0}')
    
    echo "小包测试（12K）："
    route_small=$(nexttrace --tcp --psize 12 "$ip" -p 80 | awk '/Hop/ {print $0}')

    echo -e "\n${YELLOW}=== 路由对比 ===${RESET}"
    diff_output=$(diff <(echo "$route_big") <(echo "$route_small"))
    if [ -z "$diff_output" ]; then
        echo -e "${GREEN}大小包路由一致 ✅${RESET}"
    else
        echo -e "${RED}大小包路由不一致 ❌${RESET}"
        echo "$diff_output"
    fi
    read -rp $'\n\033[33m按回车返回菜单...\033[0m'
}

# ==============================
# 全部测试
# ==============================
run_all_tests() {
    run_test "深圳移动" "120.233.18.250" <<< ""
    run_test "广州联通" "157.148.58.29" <<< ""
    run_test "广州电信" "14.116.225.60" <<< ""
}

# ==============================
# 菜单函数
# ==============================
show_menu() {
    clear
    echo -e "${GREEN}==== 大小包测试====${RESET}"
    echo -e "${GREEN}1) 移动${RESET}"
    echo -e "${GREEN}2) 联通${RESET}"
    echo -e "${GREEN}3) 电信${RESET}"
    echo -e "${GREEN}4) 全测${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp $'\033[32m请选择测试节点: \033[0m' choice

    case $choice in
        1)
            run_test "深圳移动" "120.233.18.250"
            ;;
        2)
            run_test "广州联通" "157.148.58.29"
            ;;
        3)
            run_test "广州电信" "14.116.225.60"
            ;;
        4)
            run_all_tests
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            ;;
    esac
}

# ==============================
# 主程序
# ==============================
check_install

while true; do
    show_menu
done
