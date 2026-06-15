#!/usr/bin/env bash

set -e

# ==================== 默认/初始化配置 ====================
CONFIG_FILE="/etc/vnstat_tg.conf"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
CRON_TIME="0 0 * * *" # 默认每天 0点 发送

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

SERVICE_NAME=""
PKG_MANAGER=""
PKG_REMOVE_CMD=""
PKG_INSTALL_CMD=""
INIT_SYSTEM=""

# 加载持久化配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 保存持久化配置
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat << EOF > "$CONFIG_FILE"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
CRON_TIME="${CRON_TIME}"
EOF
}

# 获取公网 IP
get_public_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || echo "未知IP"
}

# Telegram 发送基础函数
send_tg_notification() {
    local message="$1"
    load_config
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local ip=$(get_public_ip)
        local hostname=$(hostname)
        local full_message="【vnStat 流量看板】%0A====================%0A"
        full_message+="主机名称: ${hostname}%0A"
        full_message+="公网IP: ${ip}%0A"
        full_message+="====================%0A"
        full_message+="${message}"
        
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${full_message}" >/dev/null 2>&1 || true
    fi
}

# 收集所有网卡的详细流量并格式化输出给 TG
send_traffic_report() {
    if ! command -v vnstat >/dev/null 2>&1; then
        return
    fi
    
    local report=""
    local ifaces=$(vnstat --dbiflist 2>/dev/null || vnstat --showoutput 2>/dev/null | grep -E "Database|Not enough data" | awk '{print $NF}' || echo "")
    
    if [ -z "$ifaces" ] || [ "$ifaces" = "list" ]; then
        ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo || ifconfig -a | grep -E '^[a-zA-Z0-9]' | awk '{print $1}' | grep -v lo)
    fi

    for iface in $ifaces; do
        iface=$(echo "$iface" | tr -d ':,[]()')
        [ -z "$iface" ] && continue
        
        local today_line=$(vnstat -i "$iface" -d --oneline 2>/dev/null | cut -d';' -f4,5,6 || echo "")
        local month_line=$(vnstat -i "$iface" -m --oneline 2>/dev/null | cut -d';' -f9,10,11 || echo "")
        
        report+="监控接口: ${iface}%0A"
        if [ -n "$today_line" ]; then
            local rx=$(echo "$today_line" | cut -d';' -f1)
            local tx=$(echo "$today_line" | cut -d';' -f2)
            local total=$(echo "$today_line" | cut -d';' -f3)
            report+=" 今日流量: 下行 ${rx} | 上行 ${tx} | 总计 ${total}%0A"
        fi
        if [ -n "$month_line" ]; then
            local mrx=$(echo "$month_line" | cut -d';' -f1)
            local mtx=$(echo "$month_line" | cut -d';' -f2)
            local mtotal=$(echo "$month_line" | cut -d';' -f3)
            report+=" 本月累计: 下行 ${mrx} | 上行 ${mtx} | 总计 ${mtotal}%0A"
        fi
        report+="--------------------%0A"
    done

    if [ -n "$report" ]; then
        send_tg_notification "$report"
    else
        send_tg_notification "暂未收集到有效的接口流量数据。"
    fi
}

# 设置或取消每日定时任务
manage_cron() {
    local action="$1"
    local script_path=$(readlink -f "$0")
    
    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then apk add dcron; rc-update add dcron default && rc-service dcron start; fi
        if command -v apt >/dev/null 2>&1; then apt install -y cron; systemctl enable cron --now; fi
        if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then yum install -y crontabs; systemctl enable crond --now; fi
    fi

    crontab -l 2>/dev/null | grep -v "$script_path" | crontab - || true

    if [ "$action" = "set" ]; then
        load_config
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            (crontab -l 2>/dev/null; echo "${CRON_TIME} bash $script_path --cron-report >/dev/null 2>&1") | crontab -
            echo -e "${GREEN}定时流量通知任务已成功建立/更新！[ 表达式: ${CRON_TIME} ]${RESET}"
        else
            echo -e "${YELLOW}警告: 未配置 TG 参数，无法启动定时任务。${RESET}"
        fi
    elif [ "$action" = "unset" ]; then
        echo -e "${GREEN}已关闭并清理定时流量通知任务。${RESET}"
    fi
}

# 定时任务独立管理菜单
menu_cron_config() {
    while true; do
        load_config
        clear
        local cron_status="未激活"
        if crontab -l 2>/dev/null | grep -q "$(readlink -f "$0")"; then
            cron_status="已激活"
        fi

        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}       TG 定时通知管理         ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}任务状态 :${RESET} ${YELLOW}${cron_status}${RESET}"
        echo -e "${GREEN}当前时间 :${RESET} ${YELLOW}${CRON_TIME}${RESET}"
        echo -e "${GREEN}TG Token :${RESET} ${YELLOW}${TG_BOT_TOKEN:-未配置}${RESET}"
        echo -e "${GREEN}Chat ID  :${RESET} ${YELLOW}${TG_CHAT_ID:-未配置}${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN} 1. 修改 Telegram Bot Token${RESET}"
        echo -e "${GREEN} 2. 修改 Telegram Chat ID${RESET}"
        echo -e "${GREEN} 3. 修改定时发送时间${RESET}"
        echo -e "${GREEN} 4. 开启 / 更新定时通知任务${RESET}"
        echo -e "${GREEN} 5. 关闭定时通知任务${RESET}"
        echo -e "${GREEN} 6. 手动测试发送当前流量报告${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r cron_choice

        case "$cron_choice" in
            1)
                read -rp "请输入新的 TG Bot Token: " TG_BOT_TOKEN
                save_config; pause ;;
            2)
                read -rp "请输入新的 TG Chat ID: " TG_CHAT_ID
                save_config; pause ;;
            3)
                clear
                echo -e "${GREEN}==============================${RESET}"
                echo -e "${GREEN}       选择定时发送时间        ${RESET}"
                echo -e "${GREEN}==============================${RESET}"
                echo -e "  1) 每天0点"
                echo -e "  2) 每周一0点"
                echo -e "  3) 每月1号0点"
                echo -e "  4) 自定义cron表达式"
                echo -e "${GREEN}==============================${RESET}"
                echo -ne "${GREEN}请选择时间模板: ${RESET}"
                read -r time_choice
                case "$time_choice" in
                    1) CRON_TIME="0 0 * * *"; echo -e "${GREEN}已选择: 每天0点${RESET}" ;;
                    2) CRON_TIME="0 0 * * 1"; echo -e "${GREEN}已选择: 每周一0点${RESET}" ;;
                    3) CRON_TIME="0 0 1 * *"; echo -e "${GREEN}已选择: 每月1号0点${RESET}" ;;
                    4) 
                        read -rp "请输入标准的 5 位 Cron 表达式 (例如 0 12 * * *): " temp_cron
                        if [ -n "$temp_cron" ]; then
                            CRON_TIME="$temp_cron"
                            echo -e "${GREEN}已记录自定义表达式: ${CRON_TIME}${RESET}"
                        fi
                        ;;
                    *) echo -e "${YELLOW}无效选择，时间未做修改。${RESET}" ;;
                esac
                save_config; manage_cron "set"; pause ;;
            4)
                manage_cron "set"; pause ;;
            5)
                manage_cron "unset"; pause ;;
            6)
                echo "正在发送测试报告..."; send_traffic_report; echo "已提交发送请求。"; pause ;;
            0) break ;;
            *) echo "无效选项"; pause ;;
        esac
    done
}

detect_init_system() {
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        echo "未检测到支持的初始化系统 (systemd 或 openrc)"; exit 1
    fi
}

detect_service() {
    detect_init_system
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if systemctl list-unit-files | grep -q '^vnstat\.service'; then SERVICE_NAME="vnstat"
        elif systemctl list-unit-files | grep -q '^vnstatd\.service'; then SERVICE_NAME="vnstatd"
        else SERVICE_NAME="vnstat"; fi
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if [ -f /etc/init.d/vnstatd ]; then SERVICE_NAME="vnstatd"; else SERVICE_NAME="vnstat"; fi
    fi
}

detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"; PKG_INSTALL_CMD="apk update && apk add vnstat"; PKG_REMOVE_CMD="apk del vnstat"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"; PKG_INSTALL_CMD="apt update && apt install -y vnstat"; PKG_REMOVE_CMD="apt remove -y vnstat && apt autoremove -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"; PKG_INSTALL_CMD="dnf install -y epel-release || true; dnf install -y vnstat"; PKG_REMOVE_CMD="dnf remove -y vnstat"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"; PKG_INSTALL_CMD="yum install -y epel-release || true; yum install -y vnstat"; PKG_REMOVE_CMD="yum remove -y vnstat"
    else
        echo "未检测到支持的包管理器（apk/apt/dnf/yum）"; exit 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 身份运行此脚本"; echo "例如: sudo bash $0"; exit 1
    fi
}

pause() {
    echo -ne "${GREEN}按回车继续...${RESET}"
    read -r _
}

manage_service_start() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl enable "$SERVICE_NAME" --now
    elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-update add "$SERVICE_NAME" default; rc-service "$SERVICE_NAME" start; fi
}

manage_service_restart() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl restart "$SERVICE_NAME"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-service "$SERVICE_NAME" restart; fi
}

manage_service_status() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl status "$SERVICE_NAME" --no-pager
    elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-service "$SERVICE_NAME" status; fi
}

manage_service_stop() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
}

install_vnstat() {
    detect_package_manager
    echo "正在安装 vnstat..."
    bash -c "$PKG_INSTALL_CMD"
    
    echo "正在启动服务并设置开机自启..."
    manage_service_start
    echo "安装与开机自启配置完成！"
}

restart_service() {
    manage_service_restart
    echo "服务已重启：$SERVICE_NAME"
}

show_service_status() {
    manage_service_status
}

list_interfaces() {
    echo "当前网络接口："
    if command -v ip >/dev/null 2>&1; then
        ip -o link show | awk -F': ' '{print $2}' | grep -v lo
    else
        ifconfig -a | grep -E '^[a-zA-Z0-9]' | awk '{print $1}' | grep -v lo
    fi
}

add_interface() {
    list_interfaces
    read -rp "请输入要监控的网卡名: " iface
    if [ -z "$iface" ]; then echo "网卡名不能为空"; return; fi

    if command -v ip >/dev/null 2>&1; then
        if ! ip link show "$iface" >/dev/null 2>&1; then echo "网卡不存在: $iface"; return; fi
    else
        if ! ifconfig "$iface" >/dev/null 2>&1; then echo "网卡不存在: $iface"; return; fi
    fi

    vnstat -i "$iface" --add || true
    manage_service_restart
    echo "已添加监控接口: $iface"
    echo "首次采集需要等待几分钟"
}

show_default_stats() { vnstat; }

show_interface_stats() {
    list_interfaces
    read -rp "请输入要查看的网卡名: " iface
    if [ -z "$iface" ]; then echo "网卡名不能为空"; return; fi
    vnstat -i "$iface"
}

show_daily_stats() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then vnstat -i "$iface" -d; else vnstat -d; fi
}

show_monthly_stats() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then vnstat -i "$iface" -m; else vnstat -m; fi
}

live_monitor() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then vnstat -i "$iface" -l; else vnstat -l; fi
}

remove_vnstat() {
    detect_package_manager
    echo "即将卸载 vnstat..."
    read -rp "是否同时删除统计数据库 /var/lib/vnstat ? [y/N]: " remove_db

    manage_service_stop
    manage_cron "unset"
    rm -f "$CONFIG_FILE"

    bash -c "$PKG_REMOVE_CMD"

    if [[ "$remove_db" =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/vnstat
        echo "已删除数据库目录: /var/lib/vnstat"
    fi

    if [ -f /etc/vnstat.conf ]; then
        read -rp "是否删除配置文件 /etc/vnstat.conf ? [y/N]: " remove_conf
        if [[ "$remove_conf" =~ ^[Yy]$ ]]; then rm -f /etc/vnstat.conf; echo "已删除配置文件: /etc/vnstat.conf"; fi
    fi

    echo "vnstat 已卸载完成"
}

get_panel_info() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then panel_status="运行中"; else panel_status="未运行"; fi
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then panel_status="运行中"; else panel_status="未运行"; fi
    fi

    if command -v vnstat >/dev/null 2>&1; then
        panel_version=$(vnstat -v | awk '{print $2}')
        panel_port=$(vnstat --alias 2>/dev/null | head -n 1 | awk '{print $1}' || echo "常规默认")
        if [ -z "$panel_port" ] || [ "$panel_port" = "No" ]; then panel_port="常规默认"; fi
    else
        panel_version="未安装"; panel_status="未安装"; panel_port="无"
    fi
}

show_menu() {
    clear
    get_panel_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         vnStat 面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} ${YELLOW}$panel_status${RESET}"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}监控 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 vnstat${RESET}"
    echo -e "${GREEN} 2. 重启 vnstat${RESET}"
    echo -e "${GREEN} 3. 查看 服务状态${RESET}"
    echo -e "${GREEN} 4. 查看 网络接口${RESET}"
    echo -e "${GREEN} 5. 添加 监控接口${RESET}"
    echo -e "${GREEN} 6. 查看 默认流量统计${RESET}"
    echo -e "${GREEN} 7. 查看 指定网卡流量${RESET}"
    echo -e "${GREEN} 8. 查看 日流量统计${RESET}"
    echo -e "${GREEN} 9. 查看 月流量统计${RESET}"
    echo -e "${GREEN}10. 实时 流量监控${RESET}"
    echo -e "${GREEN}11. 配置 TG 定时通知任务 >>${RESET}"
    echo -e "${GREEN}12. 卸载 vnstat${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

main() {
    if [ "$1" = "--cron-report" ]; then
        send_traffic_report
        exit 0
    fi

    require_root
    load_config

    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1) install_vnstat; pause ;;
            2) restart_service; pause ;;
            3) show_service_status; pause ;;
            4) list_interfaces; pause ;;
            5) add_interface; pause ;;
            6) show_default_stats; pause ;;
            7) show_interface_stats; pause ;;
            8) show_daily_stats; pause ;;
            9) show_monthly_stats; pause ;;
            10) live_monitor ;;
            11) menu_cron_config ;;
            12) remove_vnstat; pause ;;
            0) exit 0 ;;
            *) echo "无效选项"; pause ;;
        esac
    done
}

main "$@"
