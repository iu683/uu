#!/bin/bash
set -e

# 颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 安装并启动 crontab 服务 (已适配 Alpine)
install_crontab_if_missing() {
    if ! command -v crontab &>/dev/null; then
        echo -e "${YELLOW}未检测到 crontab，正在尝试安装...${RESET}"
        if [[ -f /etc/alpine-release ]]; then
            apk add --no-cache dcron
            rc-update add crond default
            rc-service crond start
        elif [[ -f /etc/debian_version ]]; then
            apt update && apt install -y cron
            systemctl enable --now cron
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y cronie
            systemctl enable --now crond
        else
            echo -e "${RED}无法自动识别系统类型，请手动安装 crontab${RESET}"
            exit 1
        fi
        echo -e "${GREEN}crontab 安装完成并已启动服务！${RESET}"
    else
        # 已安装，确保服务启动
        if [[ -f /etc/alpine-release ]]; then
            rc-service crond start >/dev/null 2>&1
        elif command -v systemctl &>/dev/null; then
            systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1
        fi
    fi
}

# 校验数字范围 (保持原样)
validate_number() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="$4"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo -e "${RED}${name} 输入无效，应在 $min 到 $max 之间${RESET}"
        return 1
    fi
    return 0
}

# 添加任务 (保持原样)
add_cron_task() {
    read -e -p "请输入新任务的执行命令: " newquest
    [ -z "$newquest" ] && return
    echo -e "${GREEN}------------------------${RESET}"
    echo -e "${GREEN}1. 每月任务${RESET}"                
    echo -e "${GREEN}2. 每周任务${RESET}"
    echo -e "${GREEN}3. 每天任务${RESET}"  
    echo -e "${GREEN}4. 每小时任务${RESET}"
    echo -e "${GREEN}------------------------${RESET}"
    read -e -p "请选择任务类型: " dingshi
    case $dingshi in
        1)
            read -e -p "每月的几号执行任务？ (1-31): " day
            validate_number "$day" 1 31 "日期" || return
            (crontab -l 2>/dev/null; echo "0 0 $day * * $newquest") | crontab -
            ;;
        2)
            read -e -p "周几执行任务？ (0-6, 0=周日): " weekday
            validate_number "$weekday" 0 6 "星期" || return
            (crontab -l 2>/dev/null; echo "0 0 * * $weekday $newquest") | crontab -
            ;;
        3)
            read -e -p "每天几点执行任务？（小时，0-23）: " hour
            validate_number "$hour" 0 23 "小时" || return
            (crontab -l 2>/dev/null; echo "0 $hour * * * $newquest") | crontab -
            ;;
        4)
            read -e -p "每小时第几分钟执行任务？（分钟，0-59）: " minute
            validate_number "$minute" 0 59 "分钟" || return
            (crontab -l 2>/dev/null; echo "$minute * * * * $newquest") | crontab -
            ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            return
            ;;
    esac
    echo -e "${GREEN}任务添加成功！${RESET}"
}

# 删除任务 (优化以适配 Alpine 的 Bash/BusyBox 差异)
delete_cron_task() {
    local tmp_cron="/tmp/cron_list_tmp"
    crontab -l 2>/dev/null > "$tmp_cron"
    
    if [ ! -s "$tmp_cron" ]; then
        echo -e "${GREEN}当前没有定时任务${RESET}"
        return
    fi

    echo -e "${GREEN}当前定时任务列表:${RESET}"
    # 使用 awk 打印行号，不依赖 mapfile
    awk '{print NR") " $0}' "$tmp_cron"

    read -e -p "请输入要删除的任务序号（多个用空格分隔）: " indices
    [ -z "$indices" ] && return

    # 倒序排列序号，从后往前删，避免行号错位
    local sorted_indices=$(echo "$indices" | tr ' ' '\n' | sort -rn)
    
    for idx in $sorted_indices; do
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            sed -i "${idx}d" "$tmp_cron"
        fi
    done

    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    echo -e "${GREEN}删除完成！${RESET}"
}

# 编辑任务 (保持原样)
edit_cron_task() {
    if ! command -v nano &>/dev/null && ! command -v vim &>/dev/null; then
        echo -e "${RED}未检测到编辑器，正在尝试安装 nano...${RESET}"
        if [[ -f /etc/alpine-release ]]; then
            apk add --no-cache nano
        else
            apt update && apt install -y nano || yum install -y nano
        fi
    fi
    export EDITOR=$(command -v nano || command -v vim || command -v vi)
    crontab -e
}

# 菜单入口 (结构保持原样)
cron_menu() {
    install_crontab_if_missing
    while true; do
        clear
        echo -e "${GREEN}=== 定时任务管理 ===${RESET}"
        echo ""
        echo -e "${GREEN}当前定时任务列表:${RESET}"
        crontab -l 2>/dev/null || echo -e "${GREEN}(无定时任务)${RESET}"
        echo ""
        echo -e "${GREEN}------------------------${RESET}"
        echo -e "${GREEN}1. 添加定时任务${RESET}"
        echo -e "${GREEN}2. 删除定时任务${RESET}"
        echo -e "${GREEN}3. 编辑定时任务${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        echo -e "${GREEN}------------------------${RESET}"
        read -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" sub_choice

        case $sub_choice in
            1) add_cron_task ;;
            2) delete_cron_task ;;
            3) edit_cron_task ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择，请重新输入${RESET}" ;;
        esac

        echo -e "${YELLOW}按回车继续...${RESET}"
        read
    done
}

cron_menu
