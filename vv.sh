#!/bin/sh
# ss 彩色高亮增强版 v5.7 终极兼容版（深度修复 Alpine/新版内核列粘连问题）

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

# ================== 表头 ==================
printf "${BOLD}%-6s %-12s %-10s %-10s %-30s %-30s %s${RESET}\n" \
    "Proto" "State" "Recv-Q" "Send-Q" "Local:Port" "Peer:Port" "Process"

# ================== 循环显示 ==================
while true; do
    [ "$REFRESH" -eq 1 ] && clear

    # 1. 抓取原始数据 -> 2. 清洗可能产生干扰的 @数字 字符串 -> 3. 规范化空格
    $SS_CMD 2>/dev/null | awk 'NR>1' | sed -E 's/@[0-9]+ / /g' | while read -r line; do
        [[ "$line" =~ Failed.*cgroup ]] && continue
        [ -z "$line" ] && continue

        # 重新规整化地抽取字段
        proto=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        recvq=$(echo "$line" | awk '{print $3}')
        sendq=$(echo "$line" | awk '{print $4}')
        local_addr=$(echo "$line" | awk '{print $5}')
        peer_addr=$(echo "$line" | awk '{print $6}')
        process=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

        # 过滤掉非网络状态行
        if [ "$proto" = "Active" ] || [ "$proto" = "Proto" ] || [ -z "$local_addr" ]; then continue; fi

        # 提取端口 (兼容 IPv6 格式)
        port=$(echo "$local_addr" | awk -F: '{print $NF}')

        # 协议过滤
        if [ -n "$FILTER_PROTO" ] && [ "$FILTER_PROTO" != "全部" ] && [ "$proto" != "$FILTER_PROTO" ]; then
            continue
        fi

        # 端口过滤
        if [ -n "$FILTER_PORT" ]; then
            match=0
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

        # 用更安全的 [SPLIT] 替代单纯的 @@ 防止撞车
        printf "%d[SPLIT]%s[SPLIT]%s[SPLIT]%s[SPLIT]%s[SPLIT]%s[SPLIT]%s[SPLIT]%s\n" \
            "$risk" "$proto_color" "$state_color" "$recvq" "$sendq" "$local_color" "$peer_addr" "$process"

    done | sort -t '[' -k 1,1 -r | while IFS='[' read -r risk_part rest; do
        # 再次拆解安全切分的数据
        proto=$(echo "$rest" | cut -d']' -f2 | cut -d'[' -f1)
        state=$(echo "$rest" | cut -d']' -f3 | cut -d'[' -f1)
        recvq=$(echo "$rest" | cut -d']' -f4 | cut -d'[' -f1)
        sendq=$(echo "$rest" | cut -d']' -f5 | cut -d'[' -f1)
        local=$(echo "$rest" | cut -d']' -f6 | cut -d'[' -f1)
        peer=$(echo "$rest" | cut -d']' -f7 | cut -d'[' -f1)
        proc=$(echo "$rest" | cut -d']' -f8)

        [ -z "$proto" ] && continue
        
        # 打印完美的格式化输出
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
