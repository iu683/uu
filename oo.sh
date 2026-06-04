#!/bin/sh
# OpenRC/SysVinit 服务管理脚本 - 菜单适配版 v3.6
# 彻底解决 rc-service 命令不存在导致的报错，完美支持各种非典型容器环境

# ================== 颜色定义 ==================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

# ================== 配置 ==================
PAGE_SIZE=20
CURRENT_PAGE=1
TMP_MATRIX="/tmp/openrc_menu_matrix.$$"

# ================== 权限与命令侦测 ==================
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# 封装状态调用，防范命令缺失
get_service_status() {
    local svc="$1"
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" status 2>/dev/null
    elif [ -x "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" status 2>/dev/null
    else
        return 1
    fi
}

# ================== 生成完整服务列表 ==================
generate_full_list() {
    rm -f "$TMP_MATRIX"
    idx=1

    for service_path in /etc/init.d/*; do
        [ ! -f "$service_path" ] && continue
        service=$(basename "$service_path")
        
        # 排除内部引导项
        [ "$service" = "functions.sh" ] && continue
        [ "$service" = "functions" ] && continue

        # 提取脚本内描述
        desc=$(grep -E '^[[:space:]]*description=' "$service_path" | cut -d'"' -f2 | cut -d"'" -f2 | head -n 1)
        [ -z "$desc" ] && desc="无描述信息"

        # 关键词双向过滤
        if [ -n "$KEYWORD" ]; then
            if ! echo "$service" | grep -q "$KEYWORD" && ! echo "$desc" | grep -q "$KEYWORD"; then
                continue
            fi
        fi

        # 判定开机自启状态
        if command -v rc-update >/dev/null 2>&1; then
            if rc-update show 2>/dev/null | grep -Eq "^[[:space:]]*$service[[:space:]]*\|"; then
                run_levels=$(rc-update show 2>/dev/null | grep "^[[:space:]]*$service[[:space:]]*|" | awk -F'|' '{print $2}' | xargs)
                state="enabled(${run_levels})"
            else
                state="disabled"
            fi
        else
            # 如果没有 rc-update 命令，盲测级别目录
            if ls /etc/runlevels/*/"$service" >/dev/null 2>&1 || ls /etc/rc*.d/S*"$service" >/dev/null 2>&1; then
                state="enabled"
            else
                state="disabled"
            fi
        fi

        # 判定当前运行状态
        if get_service_status "$service" | grep -Eq "status: started|is running|started"; then
            act_status="started"
        elif ps aux | grep -v grep | grep -q "$service"; then
            act_status="started"
        else
            act_status="stopped"
        fi

        echo "${idx}:${service}:${state}:${act_status}:${desc}:${service_path}" >> "$TMP_MATRIX"
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

    echo -e "${BOLD}${CYAN}=== 服务管理列表（第 $CURRENT_PAGE 页 / 共 ${TOTAL_PAGES} 页，总计 ${TOTAL_COUNT} 个服务） ===${RESET}"
    printf "${BOLD}%-5s %-25s %-20s %-15s %s${RESET}\n" "No." "SERVICE" "AUTO-START" "STATUS" "DESCRIPTION"
    echo "--------------------------------------------------------------------------------------------------------"

    if [ "$TOTAL_COUNT" -gt 0 ]; then
        start_line=$(( (CURRENT_PAGE - 1) * PAGE_SIZE + 1 ))
        end_line=$(( CURRENT_PAGE * PAGE_SIZE ))

        sed -n "${start_line},${end_line}p" "$TMP_MATRIX" | awk -F':' -v r="$RED" -v g="$GREEN" -v y="$YELLOW" -v rst="$RESET" '
        {
            no=$1; service=$2; state=$3; act_status=$4; desc=$5;

            if (state ~ /enabled/) state_fmt = g state rst
            else state_fmt = y state rst

            if (act_status == "started") act_fmt = g act_status rst
            else act_fmt = r act_status rst

            printf "%-5s %-25s %-31s %-26s %s\n", no, service, state_fmt, act_fmt, desc
        }'
    else
        echo -e "       ${YELLOW}没有找到匹配的服务${RESET}"
    fi
}

# ================== 删除服务文件 ==================
delete_service() {
    service="$1"
    unit_path="$2"

    if [ -z "$unit_path" ] || [ ! -f "$unit_path" ]; then
        echo -e "${YELLOW}未找到服务脚本文件${RESET}"
        return
    fi

    echo -e "${RED}⚠ 确认要永久删除该服务脚本: $service ($unit_path) ? [y/N] ${RESET}"
    read -r confirm
    case "$confirm" in
        [yY]*)
            if command -v rc-service >/dev/null 2>&1; then $SUDO rc-service "$service" stop >/dev/null 2>&1; else [ -x "$unit_path" ] && $SUDO "$unit_path" stop >/dev/null 2>&1; fi
            if command -v rc-update >/dev/null 2>&1; then $SUDO rc-update del "$service" >/dev/null 2>&1; fi
            if $SUDO rm -f "$unit_path"; then
                echo -e "${RED}已成功删除服务脚本: $service${RESET}"
            else
                echo -e "${YELLOW}删除文件失败，请检查权限${RESET}"
            fi
            ;;
        *)
            echo -e "${YELLOW}已取消删除: $service${RESET}"
            ;;
    esac
}

# ================== 子菜单：启动 / 停止 / 重启 / 删除 ==================
submenu_action() {
    local action="$1"
    while true; do
        refresh_list
        echo -e "${GREEN}== 当前操作: $action 服务 ==${RESET}"
        printf "${GREEN}输入序号(可多选，空格分隔)，0 返回上级菜单: ${RESET}"
        read -r ARGS
        [ "$ARGS" = "0" ] || [ -z "$ARGS" ] && break

        for num in $ARGS; do
            line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
            if [ -n "$line_data" ]; then
                service=$(echo "$line_data" | cut -d':' -f2)
                service_path=$(echo "$line_data" | cut -d':' -f6)
                
                # 兼容处理核心动作
                if command -v rc-service >/dev/null 2>&1; then
                    case "$action" in
                        启动) $SUDO rc-service "$service" start && echo -e "${GREEN}已启动: $service${RESET}" ;;
                        停止) $SUDO rc-service "$service" stop && echo -e "${RED}已停止: $service${RESET}" ;;
                        重启) $SUDO rc-service "$service" restart && echo -e "${GREEN}已重启: $service${RESET}" ;;
                        删除) delete_service "$service" "$service_path" ;;
                    case; }
                elif [ -x "$service_path" ]; then
                    case "$action" in
                        启动) $SUDO "$service_path" start && echo -e "${GREEN}已启动: $service${RESET}" ;;
                        停止) $SUDO "$service_path" stop && echo -e "${RED}已停止: $service${RESET}" ;;
                        重启) $SUDO "$service_path" restart && echo -e "${GREEN}已重启: $service${RESET}" ;;
                        删除) delete_service "$service" "$service_path" ;;
                    esac
                else
                    echo -e "${YELLOW}当前系统缺少启动管理器，且脚本不可执行${RESET}"
                fi
            else
                echo -e "${YELLOW}无效序号: $num${RESET}"
            fi
        done
        generate_full_list
        printf "按回车继续..."
        read -r _
    done
}

# ================== 子菜单：开机自启管理 ==================
submenu_autostart() {
    while true; do
        refresh_list
        echo -e "${GREEN}== 开机自启管理 ==${RESET}"
        echo -e "${GREEN}1) 启用开机自启${RESET}"
        echo -e "${GREEN}2) 禁用开机自启${RESET}"
        echo -e "${GREEN}0) 返回上级菜单${RESET}"
        printf "${GREEN}请选择操作: ${RESET}"
        read -r subchoice

        case "$subchoice" in
            1) 
                printf "${GREEN}输入序号(可多选, 空格分隔): ${RESET}"
                read -r ARGS
                for num in $ARGS; do
                    line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
                    if [ -n "$line_data" ]; then
                        service=$(echo "$line_data" | cut -d':' -f2)
                        if command -v rc-update >/dev/null 2>&1; then
                            $SUDO rc-update add "$service" default && echo -e "${GREEN}已启用开机自启: $service${RESET}"
                        else
                            echo -e "${YELLOW}环境缺少 rc-update 命令，无法建立级别链接${RESET}"
                        fi
                    fi
                done ;;
            2)
                printf "${GREEN}输入序号(可多选, 空格分隔): ${RESET}"
                read -r ARGS
                for num in $ARGS; do
                    line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
                    if [ -n "$line_data" ]; then
                        service=$(echo "$line_data" | cut -d':' -f2)
                        if command -v rc-update >/dev/null 2>&1; then
                            $SUDO rc-update del "$service" >/dev/null 2>&1 && echo -e "${RED}已禁用开机自启: $service${RESET}"
                        else
                            echo -e "${YELLOW}环境缺少 rc-update 命令${RESET}"
                        fi
                    fi
                done ;;
            0) break ;;
            *) echo -e "${YELLOW}无效输入${RESET}" ;;
        esac
        generate_full_list
        printf "按回车继续..."
        read -r _
    done
}

# ================== 子菜单：查看日志 ==================
submenu_logs() {
    while true; do
        refresh_list
        echo -e "${GREEN}== 查看服务日志 ==${RESET}"
        printf "${GREEN}输入序号(单选)，0 返回上级菜单: ${RESET}"
        read -r num
        [ "$num" = "0" ] || [ -z "$num" ] && break

        line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
        if [ -n "$line_data" ]; then
            service=$(echo "$line_data" | cut -d':' -f2)
            service_path=$(echo "$line_data" | cut -d':' -f6)
            
            echo -e "${CYAN}=== 正在截取系统日志中关于 $service 的最新记录 ===${RESET}"
            if [ -f /var/log/messages ]; then
                tail -n 50 /var/log/messages | grep "$service"
            elif [ -f /var/log/syslog ]; then
                tail -n 50 /var/log/syslog | grep "$service"
            else
                # 安全兜底调用状态
                if [ -x "$service_path" ]; then
                    "$service_path" status 2>/dev/null
                fi
            fi
            echo -e "${YELLOW}\n[提示] 当前环境未检测到标准底层集中式日志，建议直接查阅运行应用本身的内部日志。${RESET}"
        else
            echo -e "${YELLOW}无效序号: $num${RESET}"
        fi
        printf "按回车继续..."
        read -r _
    done
}

# ================== 子菜单：查看状态 ==================
submenu_status() {
    while true; do
        refresh_list
        echo -e "${GREEN}== 查看服务状态 ==${RESET}"
        printf "${GREEN}输入序号(单选)，0 返回上级菜单: ${RESET}"
        read -r num
        [ "$num" = "0" ] || [ -z "$num" ] && break

        line_data=$(grep -E "^${num}:" "$TMP_MATRIX" 2>/dev/null)
        if [ -n "$line_data" ]; then
            service=$(echo "$line_data" | cut -d':' -f2)
            echo -e "\n${CYAN}=== $service 详细运行状态 ===${RESET}"
            
            get_service_status "$service"
        else
            echo -e "${YELLOW}无效序号: $num${RESET}"
        fi
        printf "\n按回车继续..."
        read -r _
    done
}

# ================== 主逻辑初始化 ==================
printf "${GREEN}请输入关键词过滤（默认显示所有服务）: ${RESET}"
read -r KEYWORD
generate_full_list

while true; do
    refresh_list
    echo -e "${GREEN}=== 主菜单 ===${RESET}"
    echo -e "${GREEN}1) 启动服务${RESET}"
    echo -e "${GREEN}2) 停止服务${RESET}"
    echo -e "${GREEN}3) 重启服务${RESET}"
    echo -e "${GREEN}4) 删除服务${RESET}"
    echo -e "${GREEN}5) 查看日志${RESET}"
    echo -e "${GREEN}6) 查看状态${RESET}"
    echo -e "${GREEN}7) 开机自启管理${RESET}"
    echo -e "${GREEN}n) 下一页   p) 上一页   r) 刷新${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    printf "${GREEN}请选择操作: ${RESET}"
    read -r choice

    case "$choice" in
        1) submenu_action "启动" ;;
        2) submenu_action "停止" ;;
        3) submenu_action "重启" ;;
        4) submenu_action "删除" ;;
        5) submenu_logs ;;
        6) submenu_status ;;
        7) submenu_autostart ;;
        n)
            TOTAL_COUNT=$(wc -l < "$TMP_MATRIX" 2>/dev/null || echo 0)
            max_page=$(( (TOTAL_COUNT + PAGE_SIZE - 1) / PAGE_SIZE ))
            if [ "$CURRENT_PAGE" -lt "$max_page" ]; then
                CURRENT_PAGE=$((CURRENT_PAGE + 1))
            fi
            ;;
        p)
            if [ "$CURRENT_PAGE" -gt 1 ]; then
                CURRENT_PAGE=$((CURRENT_PAGE - 1))
            fi
            ;;
        r)
            generate_full_list
            ;;
        0)
            break
            ;;
        *)
            echo -e "${YELLOW}无效输入${RESET}"
            sleep 1
            ;;
    esac
done

rm -f "$TMP_MATRIX"
exit 0
