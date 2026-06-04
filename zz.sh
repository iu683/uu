#!/bin/sh
# OpenRC 自启动服务管理脚本 v2.9 (颜色控制彻底修复版)
# 提示文字统一绿色，完美兼容多系统，解决 awk 颜色代码暴露及对齐错乱问题

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

# ================== 配置 ==================
PAGE_SIZE=20   # 每页显示多少条
CURRENT_PAGE=1
TMP_MATRIX="/tmp/openrc_matrix.$$"

# ================== 权限自动侦测 ==================
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# ================== 用户输入关键词 ==================
printf "${GREEN}请输入关键词过滤（默认显示所有服务）: ${RESET}"
read -r KEYWORD

# ================== 生成完整服务列表 (OpenRC 适配) ==================
generate_full_list() {
    rm -f "$TMP_MATRIX"
    idx=1

    for service_path in /etc/init.d/*; do
        [ ! -f "$service_path" ] && continue
        service=$(basename "$service_path")
        
        # 排除系统内置函数引导项
        [ "$service" = "functions.sh" ] && continue

        # 获取简短描述
        desc=$(grep -E '^[[:space:]]*description=' "$service_path" | cut -d'"' -f2 | cut -d"'" -f2 | head -n 1)
        [ -z "$desc" ] && desc="无描述信息"

        # 关键词双向过滤
        if [ -n "$KEYWORD" ]; then
            if ! echo "$service" | grep -q "$KEYWORD" && ! echo "$desc" | grep -q "$KEYWORD"; then
                continue
            fi
        fi

        # 判定自启动状态 (只存纯文本，不包含任何颜色代码)
        if rc-update show 2>/dev/null | grep -Eq "^[[:space:]]*$service[[:space:]]*\|"; then
            run_levels=$(rc-update show 2>/dev/null | grep "^[[:space:]]*$service[[:space:]]*|" | awk -F'|' '{print $2}' | xargs)
            state="enabled(${run_levels})"
        else
            state="disabled"
        fi

        # 判定当前活跃状态 (只存纯文本)
        if rc-service "$service" status 2>/dev/null | grep -q "status: started"; then
            act_status="started"
        else
            act_status="stopped"
        fi

        # 将干净的数据写入文件矩阵，使用冒号分割
        echo "${idx}:${service}:${state}:${act_status}:${desc}" >> "$TMP_MATRIX"
        idx=$((idx + 1))
    done
}

# ================== 刷新并显示某一页 ==================
refresh_list() {
    clear
    if [ ! -s "$TMP_MATRIX" ]; then
        TOTAL_COUNT=0
        TOTAL_PAGES=1
    else
        TOTAL_COUNT=$(wc -l < "$TMP_MATRIX")
        TOTAL_PAGES=$(( (TOTAL_COUNT + PAGE_SIZE - 1) / PAGE_SIZE ))
    fi

    echo -e "${BOLD}${CYAN}=== OpenRC 服务列表（第 $CURRENT_PAGE 页 / 共 ${TOTAL_PAGES} 页，总计 ${TOTAL_COUNT} 个服务） ===${RESET}"
    printf "${BOLD}%-5s %-25s %-20s %-15s %s${RESET}\n" "No." "SERVICE" "AUTO-START" "STATUS" "DESCRIPTION"
    echo "--------------------------------------------------------------------------------------------------------"

    if [ "$TOTAL_COUNT" -gt 0 ]; then
        start_line=$(( (CURRENT_PAGE - 1) * PAGE_SIZE + 1 ))
        end_line=$(( CURRENT_PAGE * PAGE_SIZE ))

        # 由 awk 统一在渲染时现场加颜色，这样完全不会影响长格式对齐，也不会暴露转义符
        sed -n "${start_line},${end_line}p" "$TMP_MATRIX" | awk -F':' -v r="$RED" -v g="$GREEN" -v y="$YELLOW" -v rst="$RESET" '
        {
            no=$1; service=$2; state=$3; act_status=$4; desc=$5;

            # 现场计算自启动颜色
            if (state ~ /enabled/) {
                state_fmt = g state rst
            } else {
                state_fmt = y state rst
            }

            # 现场计算运行状态颜色
            if (act_status == "started") {
                act_fmt = g act_status rst
            } else {
                act_fmt = r act_status rst
            }

            # 极速且格式完美的渲染输出
            printf "%-5s %-25s %-31s %-26s %s\n", no, service, state_fmt, act_fmt, desc
        }'
    else
        echo -e "       ${YELLOW}没有找到匹配的服务${RESET}"
    fi
}

# ================== 初始化 ==================
generate_full_list
refresh_list

# ================== 用户选择操作 ==================
while true; do
    echo
    printf "${GREEN}输入序号看详情，s 序号停用+禁用，r 刷新，n 下一页，p 上一页，0 退出: ${RESET}"
    read -r INPUT

    if [ "$INPUT" = "0" ] || [ -z "$INPUT" ]; then
        break

    elif [ "$INPUT" = "r" ]; then
        generate_full_list
        refresh_list

    elif [ "$INPUT" = "n" ]; then
        TOTAL_COUNT=$(wc -l < "$TMP_MATRIX" 2>/dev/null || echo 0)
        max_page=$(( (TOTAL_COUNT + PAGE_SIZE - 1) / PAGE_SIZE ))
        if [ "$CURRENT_PAGE" -lt "$max_page" ]; then
            CURRENT_PAGE=$((CURRENT_PAGE + 1))
        fi
        refresh_list

    elif [ "$INPUT" = "p" ]; then
        if [ "$CURRENT_PAGE" -gt 1 ]; then
            CURRENT_PAGE=$((CURRENT_PAGE - 1))
        fi
        refresh_list

    # 匹配输入形式如 "s 3" 或 "s 3 4 5" 停止并禁用
    elif echo "$INPUT" | grep -Eq "^s[[:space:]]*[0-9 ]+$"; then
        NUMS=$(echo "$INPUT" | sed 's/^s[[:space:]]*//')
        for num in $NUMS; do
            line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
            if [ -n "$line_data" ]; then
                service=$(echo "$line_data" | cut -d':' -f2)
                
                echo -e "\n${CYAN}正在处理服务: $service ...${RESET}"
                # 1. 停止服务
                $SUDO rc-service "$service" stop
                
                # 2. 禁用自启动
                if rc-update show | grep -q "$service"; then
                    if $SUDO rc-update del "$service" >/dev/null 2>&1; then
                        echo -e "${RED}[已禁用自启] $service${RESET}"
                    else
                        echo -e "${YELLOW}[禁用自启失败] $service${RESET}"
                    fi
                fi
            else
                echo -e "${YELLOW}无效序号: $num${RESET}"
            fi
        done
        generate_full_list
        refresh_list

    # 纯数字：查看服务状态详情
    elif echo "$INPUT" | grep -Eq "^[0-9]+$"; then
        line_data=$(grep -E "^${INPUT}:" "$TMP_MATRIX" 2>/dev/null)
        if [ -n "$line_data" ]; then
            service=$(echo "$line_data" | cut -d':' -f2)
            echo -e "\n${CYAN}=== $service 详细运行状态 ===${RESET}"
            
            rc-service "$service" status
            
            echo -e "\n${YELLOW}按回车返回菜单...${RESET}"
            read -r _
            refresh_list
        else
            echo -e "${YELLOW}无效序号: $INPUT${RESET}"
        fi
    else
        echo -e "${YELLOW}无效输入，请重新输入${RESET}"
    fi
done

# 清理痕迹
rm -f "$TMP_MATRIX"
