#!/bin/sh
# 查看进程彩色高亮脚本 v2.4 多系统适配（完美支持 Alpine Linux）
# 提示文字统一绿色，完美兼容 BusyBox

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 用户选择 ==================
echo -e "${GREEN}请选择排序方式:${RESET}"
echo -e "${GREEN}1) CPU 占用排序${RESET}"
echo -e "${GREEN}2) 内存占用排序${RESET}"

printf "${GREEN}输入选项 (默认 1 CPU): ${RESET}"
read -r sort_choice
if [ -z "$sort_choice" ]; then
    sort_choice="1"
fi

printf "${GREEN}是否启用实时刷新？(y/N): ${RESET}"
read -r resp
case "$resp" in
    [Yy]*) REFRESH=1 ;;
    *) REFRESH=0 ;;
esac

printf "${GREEN}请输入进程名关键字过滤（默认显示所有进程）: ${RESET}"
read -r FILTER_KEY

# ================== 核心执行逻辑 ==================
show_processes() {
    # 表头
    printf "${BOLD}%-8s %-15s %-8s %-8s %-8s %s${RESET}\n" \
        "PID" "USER" "CPU(%)" "MEM(%)" "TIME" "COMMAND"

    # 兼容性获取 ps 数据：Alpine 的 ps 不支持自定义 lstart，我们统一采用标准且通用的 pid,user,%cpu,%mem,time,args
    # 由于 Alpine 不支持 ps --sort，这里统一交由通用 sort 命令处理
    
    # 决定 sort 排序的列：3 为 CPU, 4 为 MEM
    if [ "$sort_choice" = "2" ]; then
        SORT_COL=4
    else
        SORT_COL=3
    fi

    # 1. 抓取进程 -> 2. 按 CPU/MEM 降序排序 -> 3. 剥离标准表头 -> 4. 动态编号前10名高亮
    ps -eo pid,user,%cpu,%mem,time,args 2>/dev/null | awk 'NR>1' | sort -k ${SORT_COL},${SORT_COL} -r -n | awk -v kw="$FILTER_KEY" -v r_col="$RED" -v rst="$RESET" '
    BEGIN {
        idx = 1
    }
    {
        pid = $1
        user = $2
        cpu = $3
        mem = $4
        time = $5
        
        # 动态拼接真正的 COMMAND (考虑到 args 本身可能包含空格)
        cmd = ""
        for (i=6; i<=NF; i++) cmd = cmd $i " "
        sub(/ *$/, "", cmd)

        # 过滤自身 awk 进程和空行
        if (cmd ~ /awk -v kw=/ || pid == "") next

        # 关键字过滤
        if (kw != "" && index(cmd, kw) == 0) next

        # 前10名渲染红色高亮，其余保持普通
        if (idx <= 10) {
            printf "%-8s %-15s %-8s %-8s %-8s %s\n", \
                r_col pid rst, r_col user rst, r_col cpu rst, r_col mem rst, time, r_col cmd rst
        } else {
            printf "%-8s %-15s %-8s %-8s %-8s %s\n", \
                pid, user, cpu, mem, time, cmd
        }
        idx++
    }'
}

# ================== 循环显示 ==================
while true; do
    if [ "$REFRESH" -eq 1 ]; then
        clear
        show_processes
        echo -e "\n${GREEN}输入 ${RED}0${GREEN}退出实时刷新，回车继续刷新...${RESET}"
        read -r input
        if [ "$input" = "0" ]; then
            break
        fi
    else
        show_processes
        break
    fi
done
