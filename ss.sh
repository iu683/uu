#!/bin/sh
# 杀进程脚本 v2.4 多系统适配版（完美支持 Alpine Linux）
# 提示文字统一绿色，完美修复过滤、序号错位及 Bash 兼容问题

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
# 获取进程数据并统一输出格式为: PID USER CPU MEM COMMAND
get_raw_ps() {
    if [ -f /etc/alpine-release ]; then
        # Alpine 引擎: 通过 top 静态快照获取 CPU 降序数据
        top -b -n 1 | awk '
            found { print $0 }
            /PID[[:space:]]+USER/ { found=1 }
        ' | awk '{
            pid = $1; user = $2; cpu = $5; mem = $6;
            cmd = ""
            for (i=7; i<=NF; i++) cmd = cmd $i " "
            sub(/ *$/, "", cmd)
            if (pid ~ /^[0-9]+$/) print pid " " user " " cpu " " mem " " cmd
        }'
    else
        # 标准 Linux 引擎: 使用 ps 标准导出并按 CPU 降序排序
        ps -eo pid,user,%cpu,%mem,args 2>/dev/null | awk 'NR>1' | sort -k 3,3 -r -n | awk '{
            pid = $1; user = $2; cpu = $3; mem = $4;
            cmd = ""
            for (i=5; i<=NF; i++) cmd = cmd $i " "
            sub(/ *$/, "", cmd)
            print pid " " user " " cpu " " mem " " cmd
        }'
    fi
}

# ================== 过滤、编号并格式化矩阵 ==================
# 过滤掉 awk 自身以及空行，保存到纯文本变量作为数据矩阵
RAW_DATA=$(get_raw_ps)

# 再次过滤并生成最终的可视化矩阵
MATCHED_MATRIX=""
idx=1

# 逐行清洗与过滤
echo "$RAW_DATA" | while read -r pid user cpu mem cmd; do
    [ -z "$pid" ] && continue
    # 过滤脚本和过滤工具自身
    if echo "$cmd" | grep -Eq "awk -v|get_raw_ps|grep -Eq"; then continue; fi
    
    # 关键字检索
    if [ -n "$FILTER_KEY" ] && ! echo "$cmd" | grep -q "$FILTER_KEY"; then
        continue
    fi
    
    # 拼装保存矩阵（用 [SPLIT] 隔离防止空格混淆）
    echo "${idx}[SPLIT]${pid}[SPLIT]${user}[SPLIT]${cpu}[SPLIT]${mem}[SPLIT]${cmd}"
    idx=$((idx + 1))
done > /tmp/proc_matrix.$$

# 计算匹配到的总行数
TOTAL_COUNT=$(wc -l < /tmp/proc_matrix.$$)

if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}没有找到匹配的进程。${RESET}"
    rm -f /tmp/proc_matrix.$$
    exit 0
fi

# 打印表头
printf "${BOLD}%-5s %-8s %-15s %-8s %-8s %s${RESET}\n" "No." "PID" "USER" "CPU(%)" "MEM(%)" "COMMAND"

# ================== 渲染并输出高亮列表 ==================
while IFS='[' read -r line; do
    [ -z "$line" ] && continue
    # 解析提取安全数据
    no=$(echo "$line" | cut -d']' -f1)
    rest=$(echo "$line" | cut -d']' -f2)
    pid=$(echo "$rest" | cut -d'[' -f2 | cut -d']' -f1)
    user=$(echo "$rest" | cut -d']' -f3 | cut -d'[' -f1)
    cpu=$(echo "$rest" | cut -d']' -f4 | cut -d'[' -f1)
    mem=$(echo "$rest" | cut -d']' -f5 | cut -d'[' -f1)
    cmd=$(echo "$rest" | cut -d']' -f6)

    # 前10名渲染红色高亮
    if [ "$no" -le 10 ]; then
        printf "%-5s %-8s %-15s %-8s %-8s %s\n" \
            "$no" "${RED}${pid}${RESET}" "${RED}${user}${RESET}" "${RED}${cpu}${RESET}" "${RED}${mem}${RESET}" "${RED}${cmd}${RESET}"
    else
        printf "%-5s %-8s %-15s %-8s %-8s %s\n" "$no" "$pid" "$user" "$cpu" "$mem" "$cmd"
    fi
done < /tmp/proc_matrix.$$

# ================== 用户选择要杀的序号 ==================
printf "\n${GREEN}请输入要杀的序号（多个用空格分开，输入 0 退出）: ${RESET}"
read -r SELECTION

if [ "$SELECTION" = "0" ] || [ -z "$SELECTION" ]; then
    echo -e "${GREEN}未操作退出${RESET}"
    rm -f /tmp/proc_matrix.$$
    exit 0
fi

# ================== 校验序号有效性 ==================
PIDS_TO_KILL=""
for num in $SELECTION; do
    # 校验是否为纯数字
    if ! echo "$num" | grep -Eq "^[0-9]+$"; then
        echo -e "${RED}错误: 输入了非法序号: $num${RESET}"
        rm -f /tmp/proc_matrix.$$
        exit 1
    fi
    if [ "$num" -lt 1 ] || [ "$num" -gt "$TOTAL_COUNT" ]; then
        echo -e "${RED}无效序号范围: $num${RESET}"
        rm -f /tmp/proc_matrix.$$
        exit 1
    fi
done

# ================== 确认操作 ==================
echo -e "${YELLOW}你确定要杀掉以下进程吗？${RESET}"
for num in $SELECTION; do
    # 从文本矩阵中精准截取对应的 PID, USER, COMMAND
    line_data=$(grep -E "^${num}\[SPLIT\]" /tmp/proc_matrix.$$)
    pid=$(echo "$line_data" | awk -F'[][]' '{print $3}')
    user=$(echo "$line_data" | awk -F'[][]' '{print $5}')
    cmd=$(echo "$line_data" | awk -F'[][]' '{print $11}')
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

# 清理临时工作矩阵
rm -f /tmp/proc_matrix.$$
