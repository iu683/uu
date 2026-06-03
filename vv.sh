#!/bin/bash
# =========================================================================
# Cron 定时任务智能管理面板（跨系统自适配 + 安全无缝交互版）
# =========================================================================

# 严格的 Root 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限（或通过 sudo）运行此脚本！\033[0m"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 自动精确识别发行版
get_os_type() {
    if [ -f /etc/alpine-release ]; then
        echo "Alpine"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu) echo "Ubuntu" ;;
            debian) echo "Debian" ;;
            centos|rhel|rocky|almalinux) echo "RedHat" ;;
            *) echo "Linux" ;;
        esac
    else
        echo "Linux"
    fi
}

OS=$(get_os_type)

# 安装并启动 crontab 服务 
install_crontab_if_missing() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo -e "${YELLOW}🔧 未检测到 crontab 组件，正在为您自动补全...${RESET}"
        case "$OS" in
            Alpine)
                apk add --no-cache dcron >/dev/null 2>&1
                rc-update add crond default >/dev/null 2>&1
                rc-service crond start >/dev/null 2>&1
                ;;
            Ubuntu|Debian)
                apt-get update -y >/dev/null 2>&1
                apt-get install -y cron >/dev/null 2>&1
                systemctl enable --now cron >/dev/null 2>&1
                ;;
            RedHat)
                yum install -y cronie >/dev/null 2>&1 || dnf install -y cronie >/dev/null 2>&1
                systemctl enable --now crond >/dev/null 2>&1
                ;;
            *)
                echo -e "${RED}❌ 无法自动识别系统类型，请手动安装 crontab！${RESET}"
                read -rp "按回车键退出..."
                exit 1
                ;;
        esac
        echo -e "${GREEN}✅ crontab 安装完成并已自动启动服务！${RESET}"
        sleep 1
    else
        # 服务保活，确保其运行
        if [ "$OS" = "Alpine" ]; then
            rc-service crond start >/dev/null 2>&1
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1
        fi
    fi
}

# 校验数字范围 
validate_number() {
    local value="$1" local min="$2" local max="$3" local name="$4"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo -e "${RED}❌ 错误：${name} 输入无效，应在 $min 到 $max 之间！${RESET}"
        return 1
    fi
    return 0
}

# 添加任务 
add_cron_task() {
    echo -e "\n${YELLOW}=== ➕ 添加新定时任务 ===${RESET}"
    echo -ne "${GREEN}请输入新任务要执行的 Shell 命令: ${RESET}"
    read -r newquest
    [ -z "$newquest" ] && return

    echo -e "\n${YELLOW}------ ⏰ 选择触发周期 ------${RESET}"
    echo -e "${GREEN}  1) 每月任务 (指定某天 00:00 执行)${RESET}"            
    echo -e "${GREEN}  2) 每周任务 (指定周几 00:00 执行)${RESET}"
    echo -e "${GREEN}  3) 每天任务 (指定每天几点 00分 执行)${RESET}"  
    echo -e "${GREEN}  4) 每小时任务 (指定每小时第几分钟 执行)${RESET}"
    echo -e "${YELLOW}----------------------------${RESET}"
    echo -ne "${GREEN}请选择时间类型: ${RESET}"
    read -r dingshi

    case "$dingshi" in
        1)
            echo -ne "${YELLOW}每月的几号执行任务？ (1-31): ${RESET}"
            read -r day
            validate_number "$day" 1 31 "日期" || { read -rp "按回车键返回..."; return; }
            (crontab -l 2>/dev/null; echo "0 0 $day * * $newquest") | crontab -
            ;;
        2)
            echo -ne "${YELLOW}周几执行任务？ (0-6, 0=周日): ${RESET}"
            read -r weekday
            validate_number "$weekday" 0 6 "星期" || { read -rp "按回车键返回..."; return; }
            (crontab -l 2>/dev/null; echo "0 0 * * $weekday $newquest") | crontab -
            ;;
        3)
            echo -ne "${YELLOW}每天几点执行任务？（小时，0-23）: ${RESET}"
            read -r hour
            validate_number "$hour" 0 23 "小时" || { read -rp "按回车键返回..."; return; }
            (crontab -l 2>/dev/null; echo "0 $hour * * * $newquest") | crontab -
            ;;
        4)
            echo -ne "${YELLOW}每小时第几分钟执行任务？（分钟，0-59）: ${RESET}"
            read -r minute
            validate_number "$minute" 0 59 "分钟" || { read -rp "按回车键返回..."; return; }
            (crontab -l 2>/dev/null; echo "$minute * * * * $newquest") | crontab -
            ;;
        *)
            echo -e "${RED}❌ 无效选择${RESET}"
            sleep 1
            return
            ;;
    esac
    echo -e "\n${GREEN}✅ 任务已成功持久化写入 crontab 定时列表！${RESET}"
    read -rp "按回车键返回菜单..."
}

# 删除任务
delete_cron_task() {
    echo -e "\n${YELLOW}=== ➖ 删除定时任务 ===${RESET}"
    local tmp_cron="/tmp/cron_list_tmp"
    
    # 安全导出，避免因 crontab 为空触发 set -e 崩溃（虽然新脚本已经拿掉了 set -e，但安全第一）
    crontab -l 2>/dev/null > "$tmp_cron" || true
    
    if [ ! -s "$tmp_cron" ]; then
        echo -e "${YELLOW}💡 当前系统中没有任何运行中的定时任务。${RESET}"
        rm -f "$tmp_cron"
        read -rp "按回车键返回菜单..."
        return
    fi

    echo -e "${GREEN}当前可删除的任务列表:${RESET}"
    awk '{print "  " NR") " $0}' "$tmp_cron"
    echo -e "${YELLOW}---------------------------------------${RESET}"
    echo -ne "${YELLOW}请输入要删除的任务序号（多个用空格分隔）: ${RESET}"
    read -r indices
    [ -z "$indices" ] && { rm -f "$tmp_cron"; return; }

    # 倒序排列序号，从后往前删，避免行号因动态缩减而错位
    local sorted_indices=$(echo "$indices" | tr ' ' '\n' | sort -rn)
    
    for idx in $sorted_indices; do
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            # 兼容适配：使用通用的 sed 行为，完美契合 Alpine Busybox 与 传统 Linux
            sed -i "${idx}d" "$tmp_cron" 2>/dev/null || sed -i "" "${idx}d" "$tmp_cron" 2>/dev/null
        fi
    done

    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    echo -e "\n${GREEN}✅ 选定任务已成功剔除并同步到系统内核！${RESET}"
    read -rp "按回车键返回菜单..."
}

# 编辑任务 
edit_cron_task() {
    echo -e "\n${YELLOW}=== 📝 手动编辑定时任务 ===${RESET}"
    if ! command -v nano >/dev/null 2>&1 && ! command -v vim >/dev/null 2>&1; then
        echo -e "${YELLOW}🔧 正在安装轻量文本编辑器 nano...${RESET}"
        case "$OS" in
            Alpine) apk add --no-cache nano >/dev/null 2>&1 ;;
            Ubuntu|Debian) apt-get update -y >/dev/null 2>&1 && apt-get install -y nano >/dev/null 2>&1 ;;
            *) yum install -y nano >/dev/null 2>&1 || dnf install -y nano >/dev/null 2>&1 ;;
        esac
    fi
    export EDITOR=$(command -v nano || command -v vim || command -v vi)
    crontab -e
}

# 预检安装
install_crontab_if_missing

# 主循环面板
while true; do
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈  Cron 定时任务管理面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 活跃任务总数 : ${YELLOW}$(crontab -l 2>/dev/null | grep -v '^#' | grep -c '[^\s]' || echo 0) 条${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 📋 当前系统定时任务快照：${RESET}"
    
    # 优雅高亮展示当前任务快照
    if crontab -l >/dev/null 2>&1; then
        crontab -l | awk '{print "   • " $0}'
    else
        echo -e "   ${YELLOW}(暂无活跃的定时任务)${RESET}"
    fi
    
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 快速添加定时任务 (引导式)${RESET}"
    echo -e "${GREEN}  2) 精准删除定时任务 (支持多选)${RESET}"
    echo -e "${GREEN}  3) 深度手动编辑任务 (打开编辑器)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read -r choice

    case "$choice" in
        1) add_cron_task ;;
        2) delete_cron_task ;;
        3) edit_cron_task ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 输入错误，无此选项${RESET}"; sleep 1 ;;
    esac
done
