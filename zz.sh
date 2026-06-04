#!/bin/sh
# 端口占用释放脚本 v2.1 多系统适配（完美支持 Alpine Linux）
# 特点：兼容 BusyBox 工具链，摆脱 Bash 数组依赖，智能平替 lsof

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 权限与命令兼容性检查 ==================
# 检查是否为 root，不是 root 且有 sudo 则加 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi
fi

# 核心：根据环境选择如何获取端口进程
get_port_processes() {
    local target_port="$1"
    # 如果是在 Alpine 环境，或者没有真正的 lsof
    if [ -f /etc/alpine-release ] || ! command -v lsof >/dev/null 2>&1; then
        # 使用 netstat 作为 Alpine 下的完美替代，提取对应端口的 PID 和进程名
        # netstat 输出中，Local Address 最后一项是端口，最后一列是 PID/Program name
        $SUDO netstat -tulnp 2>/dev/null | awk -v p=":${target_port}$" '$4 ~ p {print $0}' | \
        awk '{
            # 提取最后一列的 PID/Name，形如 "2096/sshd"
            split($NF, a, "/")
            pid = a[1]
            name = a[2]
            if (pid ~ /^[0-9]+$/) {
                # 统一输出格式为: PID USER PROTO COMMAND
                print pid " root " $1 " " name
            }
        }'
    else
        # 标准 Linux 原生原生支持 lsof 时的处理逻辑
        $SUDO lsof -i :"$target_port" -t 2>/dev/null | while read -r pid; do
            if [ -n "$pid" ]; then
                # 补全进程的其他基本信息
                local_proto=$($SUDO lsof -i :"$target_port" | grep "$pid" | awk '{print $5}' | head -n 1)
                local_cmd=$(ps -o comm= -p "$pid")
                local_user=$(ps -o user= -p "$pid")
                echo "$pid $local_user $local_proto $local_cmd"
            fi
        done
    fi
}

# ================== 用户输入端口 ==================
echo -ne "${GREEN}请输入要释放的端口号: ${RESET}"
read -r PORT
if [ -z "$PORT" ]; then
    echo -e "${RED}端口号不能为空，退出${RESET}"
    exit 1
fi

# ================== 获取占用进程 ==================
# 由于 Alpine sh 不支持数组，我们通过临时文件或文本变量来缓存数据
RAW_DATA=$(get_port_processes "$PORT")

if [ -z "$RAW_DATA" ]; then
    echo -e "${GREEN}端口 $PORT 没有被占用${RESET}"
    exit 0
fi

echo -e "${YELLOW}端口 $PORT 被以下进程占用:${RESET}"
printf "${BOLD}%-5s %-8s %-10s %-10s %s${RESET}\n" "No." "PID" "USER" "PROTO" "COMMAND"

# 解析并展示
idx=1
echo "$RAW_DATA" | while read -r pid user proto cmd; do
    printf "%-5s %-8s %-10s %-10s %s\n" "$idx" "$pid" "$user" "$proto" "$cmd"
    idx=$((idx + 1))
done

# ================== 用户选择杀掉的序号 ==================
echo -ne "\n${GREEN}请输入要杀掉的序号（多个用空格分开，输入 0 退出）: ${RESET}"
read -r SELECTION

if [ "$SELECTION" = "0" ] || [ -z "$SELECTION" ]; then
    echo -e "${GREEN}未操作，退出${RESET}"
    exit 0
fi

# ================== 转化选择的序号为 PID ==================
PIDS_TO_KILL=""
VALID_SELECTION=""

for num in $SELECTION; do
    # 根据序号定位提取对应的 PID
    target_pid=$(echo "$RAW_DATA" | awk -v n="$num" 'NR==n {print $1}')
    if [ -n "$target_pid" ]; then
        PIDS_TO_KILL="$PIDS_TO_KILL $target_pid"
        VALID_SELECTION="$VALID_SELECTION $num"
    else
        echo -e "${RED}警告: 序号 $num 不存在，已忽略${RESET}"
    fi
done

if [ -z "$PIDS_TO_KILL" ]; then
    echo -e "${RED}没有有效的序号被选择，退出${RESET}"
    exit 1
fi

# ================== 确认操作 ==================
echo -e "${YELLOW}你确定要杀掉以下进程吗？${RESET}"
for num in $VALID_SELECTION; do
    target_pid=$(echo "$RAW_DATA" | awk -v n="$num" 'NR==n {print $1}')
    echo -e "${RED}序号 $num => PID $target_pid${RESET}"
done

echo -ne "${GREEN}输入 y 确认，其他键取消: ${RESET}"
read -r CONFIRM

case "$CONFIRM" in
    [Yy]*)
        # 执行杀进程操作
        for pid in $PIDS_TO_KILL; do
            if $SUDO kill -9 "$pid" 2>/dev/null; then
                echo -e "${GREEN}成功杀掉 PID: $pid${RESET}"
            else
                echo -e "${RED}无法杀掉 PID: $pid（可能已被释放或权限不足）${RESET}"
            fi
        done
        ;;
    *)
        echo -e "${GREEN}操作已取消，退出${RESET}"
        exit 0
        ;;
esac

# ================== 检查端口是否释放 ==================
sleep 0.5 # 稍等半秒给内核释放套接字的时间
CHECK_AGAIN=$(get_port_processes "$PORT")
if [ -z "$CHECK_AGAIN" ]; then
    echo -e "${GREEN}端口 $PORT 已成功释放${RESET}"
else
    echo -e "${RED}端口 $PORT 仍被占用，请检查${RESET}"
fi
