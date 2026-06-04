#!/bin/sh
# ss 彩色高亮增强版 v5.6 多系统适配（完美支持 Alpine Linux）
# 特点：兼容 BusyBox 工具链，修复排序与参数报错

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# ================== 依赖环境检查 (针对Alpine) ==================
# Alpine 默认的 BusyBox ss 功能极弱。为了能看到进程和完整的网络状态，
# 脚本会自动尝试使用 netstat 作为备用，或者提示安装 iproute2。
SS_CMD="ss -tulna"
if [ -f /etc/alpine-release ]; then
    # 检查是否安装了全量版的 iproute2
    if ss -v 2>&1 | grep -q "iproute2"; then
        SS_CMD="ss -tulnape"
    else
        # Alpine 下如果没装 iproute2，BusyBox 的 netstat -tulnp 更好用
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
# 转换为小写 (Alpine sh 不支持 ${v,,})
FILTER_PROTO=$(echo "$FILTER_PROTO" | tr 'A-Z' 'a-z')

printf "过滤端口 (数字/多个用逗号分隔, 默认全部): "
read -r FILTER_PORT
echo -ne "${RESET}"

# ================== 表头 ==================
printf "${BOLD}%-6s %-12s %-10s %-10s %-30s %-30s %s${RESET}\n" \
    "Proto" "State" "Recv-Q" "Send-Q" "Local:Port" "Peer:Port" "Process"

# ================== 循环显示 ==================
while true; do
    [ "$REFRESH" -eq 1 ] && clear

    # 执行命令并处理
    $SS_CMD 2>/dev/null | awk 'NR>1' | while read -r line; do
        [[ "$line" =~ Failed.*cgroup ]] && continue

        # 解析字段
        proto=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        recvq=$(echo "$line" | awk '{print $3}')
        sendq=$(echo "$line" | awk '{print $4}')
        local_addr=$(echo "$line" | awk '{print $5}')
        peer_addr=$(echo "$line" | awk '{print $6}')
        process=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

        # 如果是 netstat 格式，状态列可能和 ss 不同，做个简单兼容
        if [ "$proto" = "Active" ] || [ "$proto" = "Proto" ]; then continue; fi

        # 提取端口 (兼容 IPv6 格式如 [::]:80 或 :::80)
        port=$(echo "$local_addr" | awk -F: '{print $NF}')

        # 协议过滤
        if [ -n "$FILTER_PROTO" ] && [ "$FILTER_PROTO" != "全部" ] && [ "$proto" != "$FILTER_PROTO" ]; then
            continue
        fi

        # 端口过滤 (兼容 Alpine sh 数组限制)
        if [ -n "$FILTER_PORT" ]; then
            match=0
            # 将逗号替换为空格进行遍历
            for p in $(echo "$FILTER_PORT" | tr ',' ' '); do
                if [ "$port" = "$p" ]; then
                    match=1
                    break
                fi
            done
            [ $match -eq 0 ] && continue
        fi

        # 高风险端口标记
        case "$port" in
            22|80|443|3389) risk=1 ;;
            *) risk=0 ;;
        esac

        # 协议颜色
        case "$proto" in
            tcp|TCP) proto_color="${GREEN}${proto}${RESET}" ;;
            udp|UDP) proto_color="${CYAN}${proto}${RESET}" ;;
            *) proto_color="$proto" ;;
        esac

        # 状态颜色
        case "$state" in
            LISTEN|Listen) state_color="${YELLOW}${state}${RESET}" ;;
            ESTAB|Established) state_color="${GREEN}${state}${RESET}" ;;
            SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|CLOSE-WAIT|CLOSING|LAST-ACK|TIME-WAIT)
                state_color="${PURPLE}${state}${RESET}" ;;
            UNCONN) state_color="${BLUE}${state}${RESET}" ;;
            *) state_color="$state" ;;
        esac

        # 本地地址颜色
        if echo "$local_addr" | grep -Eq "^127\.|^::1|^10\.|^192\.168\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-1]\.|^\[::1\]|^\[f"; then
            local_color="$BLUE$local_addr$RESET"
        elif [ "$risk" -eq 1 ]; then
            local_color="$RED$local_addr$RESET"
        else
            local_color="$YELLOW$local_addr$RESET"
        fi

        # 输出格式，前置 risk 用于后续排序
        printf "%d@@%s@@%s@@%s@@%s@@%s@@%s@@%s\n" \
            "$risk" "$proto_color" "$state_color" "$recvq" "$sendq" "$local_color" "$peer_addr" "$process"

    done | sort -t '@' -k 1,1 -r | while IFS='@' read -r _ proto state recvq sendq local peer proc; do
        # 打印最终结果
        printf "%-6b %-12b %-10s %-10s %-30b %-30s %s\n" \
            "$proto" "$state" "$recvq" "$sendq" "$local" "$peer" "$proc"
    done

    # ================== 退出逻辑 ==================
    if [ "$REFRESH" -eq 1 ]; then
        echo -e "\n${GREEN}输入 ${RED}0${GREEN} 回车退出实时刷新，其他回车继续...${RESET}"
        read -r input
        if [ "$input" = "0" ]; then
            echo -e "${GREEN}退出实时刷新${RESET}"
            break
        fi
    else
        break
    fi
done
