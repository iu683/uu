#!/usr/bin/env bash

set -e

# ==================== 配置区 ====================
CONFIG_FILE="/etc/vnstat_tg.conf"
PORT_DB_FILE="/etc/vnstat_tg_ports.db"
PERM_SCRIPT_PATH="/usr/local/bin/vnstat_mgr.sh"
REMOTE_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"

TG_BOT_TOKEN="8741882876:AAFExUk8A40SbCzsf5WIHh-bIqX-SxTluqQ"
TG_CHAT_ID="7061915854"
CRON_TIME="0 22 * * *" 
MONITOR_PORTS="5578" 
# ================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

SERVICE_NAME=""
PKG_MANAGER=""
PKG_REMOVE_CMD=""
PKG_INSTALL_CMD=""
INIT_SYSTEM=""

# ==================== 智能智能防空降/落地克隆逻辑 ====================
ensure_script_landed() {
    local need_download=0

    # 1. 如果本地根本没有固化文件，必须下载
    if [ ! -s "$PERM_SCRIPT_PATH" ]; then
        need_download=1
    else
        # 2. 如果本地有文件，对比当前运行的文件和本地固化文件是否一致
        # 规避 bash /usr/local/bin/vnstat_mgr.sh 导致 $0 匹配不上的问题
        if [ -f "$0" ] && ! cmp -s "$0" "$PERM_SCRIPT_PATH"; then
            need_download=1
        fi
        # 3. 如果是通过管道 bash <(curl...) 运行，$0 会是 /dev/fd/63 或 bash，也需要下载
        if [[ "$0" =~ "pipe" ]] || [[ "$0" =~ "fd" ]] || [ "$0" = "bash" ] || [ "$0" = "sh" ]; then
            need_download=1
        fi
    fi

    # 如果判定需要落地固化
    if [ "$need_download" -eq 1 ]; then
        
        if command -v curl >/dev/null 2>&1; then
            curl -sL "$REMOTE_URL" -o "$PERM_SCRIPT_PATH" || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$PERM_SCRIPT_PATH" "$REMOTE_URL" || true
        fi

        # 极端容错：利用当前内存会话克隆
        if [ ! -s "$PERM_SCRIPT_PATH" ] && [ -f "$0" ]; then
            cat "$0" > "$PERM_SCRIPT_PATH" 2>/dev/null || true
        fi

        if [ ! -s "$PERM_SCRIPT_PATH" ]; then
            echo -e "${YELLOW}警告: 获取失败，请检查网络是否能访问 GitHub 且拥有 /usr/local/bin 写入权限。${RESET}"
            exit 1
        fi

        chmod +x "$PERM_SCRIPT_PATH"
        sleep 0.5
        
        # 切换到落地后的绝对路径无缝继续运行
        exec "$PERM_SCRIPT_PATH" "$@"
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat << EOF > "$CONFIG_FILE"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
CRON_TIME="${CRON_TIME}"
MONITOR_PORTS="${MONITOR_PORTS}"
EOF
}

get_public_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || echo "未知IP"
}

get_default_interface() {
    local iface=$(ip route show | grep default | awk '{print $5}' | head -n 1)
    echo "${iface:-eth0}"
}

ensure_iptables_installed() {
    if ! command -v /sbin/iptables >/dev/null 2>&1; then
        detect_package_manager
        bash -c "$PKG_INSTALL_CMD" >/dev/null 2>&1 || true
    fi
}

init_port_iptables() {
    ensure_iptables_installed
    if ! command -v /sbin/iptables >/dev/null 2>&1; then return 0; fi
    load_config
    for port in $MONITOR_PORTS; do
        [ -z "$port" ] && continue
        if ! /sbin/iptables -L INPUT -nvx 2>/dev/null | grep -q "tcp.*dpt:$port"; then /sbin/iptables -A INPUT -p tcp --dport "$port" >/dev/null 2>&1 || true; fi
        if ! /sbin/iptables -L INPUT -nvx 2>/dev/null | grep -q "udp.*dpt:$port"; then /sbin/iptables -A INPUT -p udp --dport "$port" >/dev/null 2>&1 || true; fi
        if ! /sbin/iptables -L OUTPUT -nvx 2>/dev/null | grep -q "tcp.*spt:$port"; then /sbin/iptables -A OUTPUT -p tcp --sport "$port" >/dev/null 2>&1 || true; fi
        if ! /sbin/iptables -L OUTPUT -nvx 2>/dev/null | grep -q "udp.*spt:$port"; then /sbin/iptables -A OUTPUT -p udp --sport "$port" >/dev/null 2>&1 || true; fi
    done
}

format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -le 0 ] 2>/dev/null; then echo "0 B"; return; fi
    local units=('B' 'KB' 'MB' 'GB' 'TB')
    local i=0
    while [ $(echo "$bytes > 1024" | bc -l) -eq 1 ] && [ $i -lt 4 ]; do
        bytes=$(echo "scale=2; $bytes / 1024" | bc -l)
        i=$((i+1))
    done
    echo "${bytes} ${units[$i]}"
}

get_port_raw_bytes() {
    local port=$1
    local direction=$2
    if ! command -v /sbin/iptables >/dev/null 2>&1; then echo "0"; return; fi
    local tcp_bytes=$(/sbin/iptables -L $direction -nvx 2>/dev/null | grep "tcp" | grep -E "(dpt:$port|spt:$port)" | awk '{print $2}' | awk '{s+=$1} END {print s}')
    local udp_bytes=$(/sbin/iptables -L $direction -nvx 2>/dev/null | grep "udp" | grep -E "(dpt:$port|spt:$port)" | awk '{print $2}' | awk '{s+=$1} END {print s}')
    echo $(( ${tcp_bytes:-0} + ${udp_bytes:-0} ))
}

get_db_value() {
    local key=$1
    if [ -f "$PORT_DB_FILE" ]; then
        grep "^${key}=" "$PORT_DB_FILE" | cut -d'=' -f2 || echo "0"
    else
        echo "0"
    fi
}

save_db_value() {
    local key=$1
    local val=$2
    touch "$PORT_DB_FILE"
    if grep -q "^${key}=" "$PORT_DB_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$PORT_DB_FILE"
    else
        echo "${key}=${val}" >> "$PORT_DB_FILE"
    fi
}

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
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" -d "chat_id=${TG_CHAT_ID}" -d "text=${full_message}" >/dev/null 2>&1 || true
    fi
}

send_traffic_report() {
    init_port_iptables
    load_config
    local report=""
    local iface=$(get_default_interface)
    
    if command -v vnstat >/dev/null 2>&1; then
        local today_line=$(vnstat -i "$iface" -d --oneline 2>/dev/null | cut -d';' -f4,5,6 || echo "")
        local month_line=$(vnstat -i "$iface" -m --oneline 2>/dev/null | cut -d';' -f9,10,11 || echo "")
        report+="📡 默认网卡: ${iface}%0A"
        if [ -n "$today_line" ]; then report+=" 今日总流量: 下行 $(echo "$today_line" | cut -d';' -f1) | 上行 $(echo "$today_line" | cut -d';' -f2) | 总计 $(echo "$today_line" | cut -d';' -f3)%0A"; fi
        if [ -n "$month_line" ]; then report+=" 本月总累计: 下行 $(echo "$month_line" | cut -d';' -f1) | 上行 $(echo "$month_line" | cut -d';' -f2) | 总计 $(echo "$month_line" | cut -d';' -f3)%0A"; fi
        report+="====================%0A"
    else
        report+="📡 默认网卡: ${iface} (vnStat未安装)%0A====================%0A"
    fi

    if command -v /sbin/iptables >/dev/null 2>&1; then
        report+="🔌 独立端口流量统计:%0A"
        for port in $MONITOR_PORTS; do
            [ -z "$port" ] && continue
            
            local current_rx=$(get_port_raw_bytes "$port" "INPUT")
            local current_tx=$(get_port_raw_bytes "$port" "OUTPUT")
            
            local base_day_rx=$(get_db_value "port_${port}_base_day_rx")
            local base_day_tx=$(get_db_value "port_${port}_base_day_tx")
            local base_month_rx=$(get_db_value "port_${port}_base_month_rx")
            local base_month_tx=$(get_db_value "port_${port}_base_month_tx")
            
            local day_rx=$((current_rx - base_day_rx))
            local day_tx=$((current_tx - base_day_tx))
            [ $day_rx -lt 0 ] && day_rx=$current_rx
            [ $day_tx -lt 0 ] && day_tx=$current_tx
            
            local month_rx=$((current_rx - base_month_rx))
            local month_tx=$((current_tx - base_month_tx))
            [ $month_rx -lt 0 ] && month_rx=$current_rx
            [ $month_tx -lt 0 ] && month_tx=$current_tx

            report+=" 端口 [ ${port} ]%0A"
            report+="   今日累计(实时) -> 下载: $(format_bytes "$day_rx") | 上传: $(format_bytes "$day_tx") | 总计: $(format_bytes "$((day_rx + day_tx))")%0A"
            report+="   本月累计(实时) -> 下载: $(format_bytes "$month_rx") | 上传: $(format_bytes "$month_tx") | 总计: $(format_bytes "$((month_rx + month_tx))")%0A"
        done
    fi
    send_tg_notification "$report"
}

manage_cron() {
    local action="$1"
    mkdir -p /root/.cache/crontab 2>/dev/null || true
    local tmp_cron="/tmp/vnstat_cron_bak"
    crontab -l 2>/dev/null | grep -v "cron-report" | grep -v "cron-slice" > "$tmp_cron" || true

    if [ "$action" = "set" ]; then
        load_config
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            echo "0 0 * * * bash $PERM_SCRIPT_PATH --cron-slice >/dev/null 2>&1" >> "$tmp_cron"
            echo "${CRON_TIME} bash $PERM_SCRIPT_PATH --cron-report >/dev/null 2>&1" >> "$tmp_cron"
            crontab "$tmp_cron"
            echo -e "${GREEN}定时任务激活成功！自定义通知与全自动切片已完美对齐。${RESET}"
        else
            echo -e "${YELLOW}警告: 未配置 TG 参数。${RESET}"
        fi
    elif [ "$action" = "unset" ]; then
        crontab "$tmp_cron"
        echo -e "${GREEN}已关闭定时流量通知任务。${RESET}"
    fi
    rm -f "$tmp_cron"
}

menu_cron_config() {
    while true; do
        load_config
        init_port_iptables
        clear
        local cron_status="未激活"
        if crontab -l 2>/dev/null | grep -q "cron-report"; then cron_status="已激活"; fi

        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}    ◈  TG 定时通知管理  ◈     ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}任务状态 :${RESET} ${YELLOW}${cron_status}${RESET}"
        echo -e "${GREEN}当前频次 :${RESET} ${YELLOW}${CRON_TIME}${RESET}"
        echo -e "${GREEN}TG Token :${RESET} ${YELLOW}${TG_BOT_TOKEN:-未配置}${RESET}"
        echo -e "${GREEN}Chat ID  :${RESET} ${YELLOW}${TG_CHAT_ID:-未配置}${RESET}"
        echo -e "${GREEN}监控端口 :${RESET} ${YELLOW}${MONITOR_PORTS}${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN} 1. 修改 Telegram Bot Token${RESET}"
        echo -e "${GREEN} 2. 修改 Telegram Chat ID${RESET}"
        echo -e "${GREEN} 3. 修改需要监控的端口${RESET}"
        echo -e "${GREEN} 4. 修改定时发送时间${RESET}"
        echo -e "${GREEN} 5. 开启定时通知任务${RESET}"
        echo -e "${GREEN} 6. 关闭定时通知任务${RESET}"
        echo -e "${GREEN} 7. 手动测试发送当前流量报告${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r cron_choice

        case "$cron_choice" in
            1) read -rp "请输入新的 TG Bot Token: " TG_BOT_TOKEN; save_config; pause ;;
            2) read -rp "请输入新的 TG Chat ID: " TG_CHAT_ID; save_config; pause ;;
            3)
                echo -e "当前监控的端口为: ${YELLOW}${MONITOR_PORTS}${RESET}"
                read -rp "请输入新的端口: " input_ports
                if [ -n "$input_ports" ]; then MONITOR_PORTS="$input_ports"; save_config; init_port_iptables; fi
                pause ;;
            4)
                echo -e "请选择通知发送时间模板:"
                echo "1) 每天 0:00"
                echo "2) 每天 22:00 (推荐)"
                echo "3) 每周一 0:00"
                echo "4) 每月1号 0:00"
                echo "5) 手动输入 Cron 表达式"
                read -rp "请输入选项 [1-5]: " t_choice
                case "$t_choice" in
                    1) CRON_TIME="0 0 * * *" ;;
                    2) CRON_TIME="0 22 * * *" ;;
                    3) CRON_TIME="0 0 * * 1" ;;
                    4) CRON_TIME="0 0 1 * *" ;;
                    5) read -rp "请输入标准的 Cron 表达式 (如 0 12 * * *): " CRON_TIME ;;
                esac
                save_config; manage_cron "set"; pause ;;
            5) manage_cron "set"; pause ;;
            6) manage_cron "unset"; pause ;;
            7) echo "正在发送测试报告..."; send_traffic_report; echo "已提交发送请求。"; pause ;;
            0) break ;;
            *) echo "无效选项"; pause ;;
        esac
    done
}

detect_init_system() {
    if command -v systemctl >/dev/null 2>&1; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else echo "未检测到支持的初始化系统"; exit 1; fi
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
    if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"; PKG_INSTALL_CMD="apk update && apk add vnstat bc iptables cronie || apk add vnstat bc iptables dcron"; PKG_REMOVE_CMD="apk del vnstat"
    elif command -v apt >/dev/null 2>&1; then PKG_MANAGER="apt"; PKG_INSTALL_CMD="apt update && apt install -y vnstat bc iptables cron"; PKG_REMOVE_CMD="apt remove -y vnstat && apt autoremove -y"
    elif command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; PKG_INSTALL_CMD="dnf install -y epel-release || true; dnf install -y vnstat bc iptables crontabs"; PKG_REMOVE_CMD="dnf remove -y vnstat"
    elif command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"; PKG_INSTALL_CMD="yum install -y epel-release || true; yum install -y vnstat bc iptables crontabs"; PKG_REMOVE_CMD="yum remove -y vnstat"
    else echo "未检测到支持的包管理器"; exit 1; fi
}

require_root() { if [ "$(id -u)" -ne 0 ]; then echo "请使用 root 身份运行此脚本"; exit 1; fi; }
pause() { echo -ne "${GREEN}按回车继续...${RESET}"; read -r _ ; }

manage_service_start() { detect_service; if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl enable "$SERVICE_NAME" --now; elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-update add "$SERVICE_NAME" default; rc-service "$SERVICE_NAME" start; fi; }
manage_service_restart() { detect_service; if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl restart "$SERVICE_NAME"; elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-service "$SERVICE_NAME" restart; fi; }
manage_service_status() { detect_service; if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl status "$SERVICE_NAME" --no-pager; elif [ "$INIT_SYSTEM" = "openrc" ]; then rc-service "$SERVICE_NAME" status; fi; }
manage_service_stop() { detect_service; if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; elif [ "$INIT_SYSTEM" = "openrc" ] ; then rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true; rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true; fi; }

install_vnstat() { detect_package_manager; echo "正在安装组件..."; bash -c "$PKG_INSTALL_CMD"; manage_service_start; init_port_iptables; echo "配置完成！"; }
restart_service() { manage_service_restart; }
show_service_status() { manage_service_status; }
list_interfaces() { ip -o link show | awk -F': ' '{print $2}' | grep -v lo; }
add_interface() { list_interfaces; read -rp "网卡名: " iface; [ -n "$iface" ] && vnstat -i "$iface" --add && manage_service_restart; }
show_default_stats() { vnstat; }
show_interface_stats() { list_interfaces; read -rp "网卡名: " iface; [ -n "$iface" ] && vnstat -i "$iface"; }
show_daily_stats() { vnstat -d; }
show_monthly_stats() { vnstat -m; }
live_monitor() { vnstat -l; }

remove_vnstat() {
    detect_package_manager; manage_service_stop; manage_cron "unset"
    if command -v /sbin/iptables >/dev/null 2>&1; then
        for port in $MONITOR_PORTS; do
            /sbin/iptables -D INPUT -p tcp --dport "$port" >/dev/null 2>&1 || true
            /sbin/iptables -D INPUT -p udp --dport "$port" >/dev/null 2>&1 || true
            /sbin/iptables -D OUTPUT -p tcp --sport "$port" >/dev/null 2>&1 || true
            /sbin/iptables -D OUTPUT -p udp --sport "$port" >/dev/null 2>&1 || true
        done
    fi
    bash -c "$PKG_REMOVE_CMD"
    rm -f "$CONFIG_FILE" "$PORT_DB_FILE" "$PERM_SCRIPT_PATH"
    echo "清理完成！"; exit 0
}

get_panel_info() {
    detect_service
    if [ "$INIT_SYSTEM" = "systemd" ] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then panel_status="运行中"
    elif [ "$INIT_SYSTEM" = "openrc" ] && rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then panel_status="运行中"
    else panel_status="未运行"; fi
    if command -v vnstat >/dev/null 2>&1; then panel_version=$(vnstat -v | awk '{print $2}'); panel_port=$(get_default_interface)
    else panel_version="未安装"; panel_status="未安装"; panel_port="无"; fi
}

show_menu() {
    clear; get_panel_info
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     ◈   vnStat 面板   ◈     ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} ${YELLOW}$panel_status${RESET}"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}网卡 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 vnstat${RESET}"
    echo -e "${GREEN} 2. 重启 服务${RESET}"
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

    if [ "$1" = "--cron-slice" ]; then
        load_config
        local is_first_day_of_month=$(date +%d)
        for port in $MONITOR_PORTS; do
            [ -z "$port" ] && continue
            local current_rx=$(get_port_raw_bytes "$port" "INPUT")
            local current_tx=$(get_port_raw_bytes "$port" "OUTPUT")
            save_db_value "port_${port}_base_day_rx" "$current_rx"
            save_db_value "port_${port}_base_day_tx" "$current_tx"
            if [ "$is_first_day_of_month" = "01" ]; then
                save_db_value "port_${port}_base_month_rx" "$current_rx"
                save_db_value "port_${port}_base_month_tx" "$current_tx"
            fi
        done
        exit 0
    fi
    
    require_root
    ensure_script_landed "$@"
    save_config
    init_port_iptables
    
    while true; do
        show_menu; read -r choice
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
            12) remove_vnstat ;;
            0) exit 0 ;;
            *) echo "无效选项"; pause ;;
        esac
    done
}

main "$@"
