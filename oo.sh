#!/bin/sh
# 查看进程彩色高亮脚本 v2.5 动态双引擎版（彻底解决 Alpine ps 无输出问题）
# 提示文字统一绿色，完美兼容 BusyBox /proc & top 机制

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

# ================== 核心显示逻辑 ==================
show_processes() {
    # 打印统一表头
    printf "${BOLD}%-8s %-12s %-8s %-8s %s${RESET}\n" \
        "PID" "USER" "CPU(%)" "MEM(%)" "COMMAND"

    # 检测是否为 Alpine 环境
    if [ -f /etc/alpine-release ]; then
        # ---------------- Alpine 引擎 (使用 top 静态快照) ----------------
        # BusyBox top 输出格式通常为: PID USER STATUS VSZ %CPU %MEM COMMAND
        # 排序：top 默认按 CPU 排序。如果是内存排序，用 sort 对第 6 列操作
        if [ "$sort_choice" = "2" ]; then
            SORT_CMD="sort -k 6,6 -r -n"
        else
            SORT_CMD="sort -k 5,5 -r -n"
        fi

        top -b -n 1 | awk '
            found { print $0 }
            /PID[[:space:]]+USER/ { found=1 }
        ' | $SORT_CMD 2>/dev/null | awk -v kw="$FILTER_KEY" -v r_col="$RED" -v rst="$RESET" '
            BEGIN { idx = 1 }
            {
                pid = $1; user = $2; cpu = $5; mem = $6;
                # 提取 COMMAND
                cmd = ""
                for (i=7; i<=NF; i++) cmd = cmd $i " "
                sub(/ *$/, "", cmd)

                if (pid == "" || pid ~ /[^0-9]/) next
                if (kw != "" && index(cmd, kw) == 0) next

                if (idx <= 10) {
                    printf "%-8s %-12s %-8s %-8s %s\n", \
                        r_col pid rst, r_col user rst, r_col cpu rst, r_col mem rst, r_col cmd rst
                } else {
                    printf "%-8s %-12s %-8s %-8s %s\n", pid, user, cpu, mem, cmd
                }
                idx++
            }
        '
    else
        # ---------------- 标准 Linux 引擎 (使用 ps) ----------------
        if [ "$sort_choice" = "2" ]; then
            SORT_COL=4
        else
            SORT_COL=3
        fi

        ps -eo pid,user,%cpu,%mem,args 2>/dev/null | awk 'NR>1' | sort -k ${SORT_COL},${SORT_COL} -r -n | awk -v kw="$FILTER_KEY" -v r_col="$RED" -v rst="$RESET" '
            BEGIN { idx = 1 }
            {
                pid = $1; user = $2; cpu = $3; mem = $4;
                cmd = ""
                for (i=5; i<=NF; i++) cmd = cmd $i " "
                sub(/ *$/, "", cmd)

                if (cmd ~ /awk -v kw=/ || pid == "") next
                if (kw != "" && index(cmd, kw) == 0) next

                if (idx <= 10) {
                    printf "%-8s %-12s %-8s %-8s %s\n", \
                        r_col pid rst, r_col user rst, r_col cpu rst, r_col mem rst, r_col cmd rst
                } else {
                    printf "%-8s %-12s %-8s %-8s %s\n", pid, user, cpu, mem, cmd
                }
                idx++
            }
        '
    fi
}

# ================== 循环显示 ==================
while true; do
    if [ "$REFRESH" -eq 1 ]; then
        clear
        show_processes
        echo -e "\n${GREEN}输入 ${RED}0${GREEN} 退出实时刷新，回车继续刷新...${RESET}"
        read -r input
        if [ "$input" = "0" ]; then
            break
        fi
    else
        show_processes
        break
    fi
done
