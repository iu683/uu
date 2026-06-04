#!/bin/sh
# 杀进程脚本 v2.5 终极稳固版（彻底修复 1[SPLIT 整数比较报错与切分 Bug）
# 提示文字统一绿色，完美兼容多系统

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 权限自动侦测 ==================
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# ================== 用户输入 ==================
printf "${GREEN}请输入进程名关键字过滤（默认显示所有进程）: ${RESET}"
read -r FILTER_KEY

# ================== 核心：双引擎数据采集 ==================
get_raw_ps() {
    if [ -f /etc/alpine-release ]; then
        # Alpine 引擎: 通过 top 静态快照获取数据
        top -b -n 1 | awk '
            found { print $0 }
            /PID[[:space:]]+USER/ { found=1 }
        ' | awk '{
            pid = $1; user = $2; cpu = $5; mem = $6;
            cmd = ""
            for (i=7; i<=NF; i++) cmd = cmd $i " "
            sub(/ *$/, "", cmd)
            if (pid ~ /^[0-9]+$/) print pid ":" user ":" cpu ":" mem ":" cmd
        }'
    else
        # 标准 Linux 引擎: 使用 ps 标准导出并按 CPU 降序排序
        ps -eo pid,user,%cpu,%mem,args 2>/dev/null | awk 'NR>1' | sort -k 3,3 -r -n | awk '{
            pid = $1; user = $2; cpu = $3; mem = $4;
            cmd = ""
            for (i=5; i<=NF; i++) cmd = cmd $i " "
            sub(/ *$/, "", cmd)
            print pid ":" user ":" cpu ":" mem ":" cmd
        }'
    fi
}

# ================== 数据过滤与矩阵创建 ==================
TMP_FILE="/tmp/proc_matrix.$$"
idx=1

get_raw_ps | while IFS=':' read -r pid user cpu mem cmd; do
    [ -z "$pid" ] && continue
    
    # 过滤脚本和过滤工具自身
    if echo "$cmd" | grep -Eq "awk -v|get_raw_ps|grep -Eq|curl|main/ss.sh"; then 
        continue
    fi
    
    # 关键字检索
    if [ -n "$FILTER_KEY" ] && ! echo "$cmd" | grep -q "$FILTER_KEY"; then
        continue
    fi
    
    # 使用单一冒号隔离，确保稳固
    echo "${idx}:${pid}:${user}:${cpu}:${mem}:${cmd}" >> "$TMP_FILE"
    idx=$((idx + 1))
done

if [ ! -s "$TMP_FILE" ]; then
    echo -e "${GREEN}没有找到匹配的进程。${RESET}"
    rm -f "$TMP_FILE"
    exit 0
fi

# 获取匹配到的总行数
TOTAL_COUNT=$(wc -l < "$TMP_FILE")

# ================== 渲染并输出高亮列表 ==================
# 打印标准统一表头
printf "${BOLD}%-5s %-8s %-15s %-8s %-8s %s${RESET}\n" "No." "PID" "USER" "CPU(%)" "MEM(%)" "COMMAND"

# 一律交由 awk 极其稳定的格式化引擎输出渲染，杜绝 shell 报错
awk -F':' -v r_col="$RED" -v rst="$RESET" '
{
    no=$1; pid=$2; user=$3; cpu=$4; mem=$5; cmd=$6;
    if (no <= 10) {
        printf "%-5s %-8s %-15s %-8s %-8s %s\n", \
            no, r_col pid rst, r_col user rst, r_col cpu rst, r_col mem rst, r_col cmd rst
    } else {
        printf "%-5s %-8s %-15s %-8s %-8s %s\n", no, pid, user, cpu, mem, cmd
    }
}' "$TMP_FILE"

# ================== 用户选择要杀的序号 ==================
printf "\n${GREEN}请输入要杀的序号（多个用空格分开，输入 0 退出）: ${RESET}"
read -r SELECTION

if [ "$SELECTION" = "0" ] || [ -z "$SELECTION" ]; then
    echo -e "${GREEN}未操作退出${RESET}"
    rm -f "$TMP_FILE"
    exit 0
fi

# ================== 校验序号有效性 ==================
for num in $SELECTION; do
    if ! echo "$num" | grep -Eq "^[0-9]+$"; then
        echo -e "${RED}错误: 输入了非法序号: $num${RESET}"
        rm -f "$TMP_FILE"
        exit 1
    fi
    if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL_COUNT" ]; then
        echo -e "${RED}无效序号范围: $num${RESET}"
        rm -f "$TMP_FILE"
        exit 1
    fi
done

# ================== 确认操作并执行 ==================
echo -e "${YELLOW}你确定要杀掉以下进程吗？${RESET}"
PIDS_TO_KILL=""
for num in $SELECTION; do
    # 基于单冒号极其精准地定位行内属性
    line_data=$(grep -E "^${num}:" "$TMP_FILE")
    pid=$(echo "$line_data" | cut -d':' -f2)
    user=$(echo "$line_data" | cut -d':' -f3)
    cmd=$(echo "$line_data" | cut -d':' -f6)
    
    echo -e "${RED}序号 $num => PID $pid, USER $user, CMD $cmd${RESET}"
    PIDS_TO_KILL="$PIDS_TO_KILL $pid"
done

printf "${GREEN}输入 y 确认，其他键取消: ${RESET}"
read -r CONFIRM

case "$CONFIRM" in
    [Yy]*)
        for pid in $PIDS_TO_KILL; do
            if $SUDO kill -9 "$pid" 2>/dev/null; then
                echo -e "${GREEN}成功杀掉 PID: $pid${RESET}"
            else
                echo -e "${RED}无法杀掉 PID: $pid（可能不存在或权限不足）${RESET}"
            fi
        done
        ;;
    *)
        echo -e "${GREEN}操作已取消，退出${RESET}"
        ;;
esac

# 清理工作矩阵
rm -f "$TMP_FILE"
