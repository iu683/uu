#!/bin/sh
# ss 彩色高亮增强版 v5.8 纯 awk 驱动版（彻底解决 Alpine 错位与漏字段问题）

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 依赖环境检查 ==================
SS_CMD="ss -tulna"
if [ -f /etc/alpine-release ]; then
    if ss -v 2>&1 | grep -q "iproute2"; then
        SS_CMD="ss -tulnape"
    else
        SS_CMD="netstat -tulnp"
    fi
else
    SS_CMD="ss -tulnape"
fi

# ================== 用户输入 ==================
echo -ne "${GREEN}"
printf "是否启用实时刷新？(y/N): "
read -r resp
case "$resp" in
    [Yy]*) REFRESH=1 ;;
    *) REFRESH=0 ;;
esac

printf "过滤协议 (tcp/udp, 默认全部): "
read -r FILTER_PROTO
FILTER_PROTO=$(echo "$FILTER_PROTO" | tr 'A-Z' 'a-z')

printf "过滤端口 (数字/多个用逗号分隔, 默认全部): "
read -r FILTER_PORT
echo -ne "${RESET}"

# ================== 核心执行逻辑 ==================
run_monitor() {
    # 打印表头
    printf "${BOLD}%-6s %-12s %-10s %-10s %-30s %-30s %s${RESET}\n" \
        "Proto" "State" "Recv-Q" "Send-Q" "Local:Port" "Peer:Port" "Process"

    # 执行底层网络命令，全权交给 awk 处理
    $SS_CMD 2>/dev/null | awk -v f_proto="$FILTER_PROTO" -v f_port="$FILTER_PORT" '
    BEGIN {
        # 初始化颜色变量传递给 awk
        RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"
        PURPLE="\033[35m"; CYAN="\033[36m"; RESET="\033[0m"; BOLD="\033[1m"
        
        # 将过滤端口拆解为数组
        if (f_port != "") {
            split(f_port, port_arr, ",")
            for (i in port_arr) f_port_map[port_arr[i]] = 1
        }
    }
    NR>1 {
        # 1. 字段清洗：如果在某些特殊列中发现了类似 @128 等连体婴字符，将其剥离
        for (i=1; i<=NF; i++) {
            if ($i ~ /^@[0-9]+$/) {
                # 如果单独成一列，则移除该列并平移后续字段
                for (j=i; j<NF; j++) $j = $(j+1)
                NF--
                i--
                continue
            }
            if ($i ~ /^@[0-9]+@@/) {
                sub(/^@[0-9]+@@/, "", $i)
            }
        }

        proto = $1
        state = $2
        recvq = $3
        sendq = $4
        local_addr = $5
        peer_addr = $6
        
        # 动态组装进程列
        proc = ""
        for (i=7; i<=NF; i++) proc = proc $i " "
        sub(/ *$/, "", proc)

        # 过滤掉非法的表头行
        if (proto == "Active" || proto == "Proto" || local_addr == "") next

        # 2. 提取端口
        split(local_addr, addr_parts, ":")
        port = addr_parts[length(addr_parts)]

        # 3. 过滤逻辑
        if (f_proto != "" && f_proto != "全部" && tolower(proto) != f_proto) next
        if (f_port != "") {
            if (!(port in f_port_map)) next
        }

        # 4. 计算风险系数 (用于排序)
        risk = 0
        if (port ~ /^(22|80|443|3389)$/) risk = 1

        # 5. 协议着色
        p_l = tolower(proto)
        if (p_l ~ /tcp/) proto_c = GREEN proto RESET
        else if (p_l ~ /udp/) proto_c = CYAN proto RESET
        else proto_c = proto

        # 6. 状态着色
        if (state ~ /LISTEN|Listen/) state_c = YELLOW state RESET
        else if (state ~ /ESTAB|Established/) state_c = GREEN state RESET
        else if (state ~ /SYN|FIN|WAIT|CLOSE|CLOSING|LAST|TIME/) state_c = PURPLE state RESET
        else if (state ~ /UNCONN/) state_c = BLUE state RESET
        else state_c = state

        # 7. 本地地址着色
        if (local_addr ~ /^127\./ || local_addr ~ /^::1/ || local_addr ~ /^10\./ || local_addr ~ /^192\.168\./ || local_addr ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ || local_addr ~ /^\[::1\]/ || local_addr ~ /^\[f/) {
            local_c = BLUE local_addr RESET
        } else if (risk == 1) {
            local_c = RED local_addr RESET
        } else {
            local_c = YELLOW local_addr RESET
        }

        # 将处理好的整行连同 risk 权重压入格式化字符串，留待后面排序
        # 使用 \t 作为绝对安全的安全隔离符
        printf "%d\t%-6s\t%-12s\t%-10s\t%-10s\t%-30s\t%-30s\t%s\n", \
            risk, proto_c, state_c, recvq, sendq, local_c, peer_addr, proc
    }' | sort -k1,1 -r -n | cut -f2- 
    # 注：通过 sort 排序后，cut -f2- 顺手把用来排序的 risk 辅助列隐去，还原本色
}

# ================== 循环控制 ==================
while true; do
    if [ "$REFRESH" -eq 1 ]; then
        clear
        run_monitor
        echo -e "\n${GREEN}输入 ${RED}0${GREEN} 回车退出实时刷新，其他回车继续...${RESET}"
        read -r input
        if [ "$input" = "0" ]; then
            echo -e "${GREEN}退出实时刷新${RESET}"
            break
        fi
    else
        run_monitor
        break
    fi
done
