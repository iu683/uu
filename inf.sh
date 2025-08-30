#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
white="\033[37m"
re="\033[0m"

# ================== Telegram 配置 ==================
TG_CONFIG_FILE="$HOME/.vps_tg_config"
OUTPUT_FILE="/tmp/vps_system_info.txt"

setup_telegram(){
    if [ -f "$TG_CONFIG_FILE" ]; then
        source "$TG_CONFIG_FILE"
    else
        echo "第一次运行，需要配置 Telegram 参数"
        echo "请输入 Telegram Bot Token:"
        read -r TG_BOT_TOKEN
        echo "请输入 Telegram Chat ID:"
        read -r TG_CHAT_ID
        echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$TG_CONFIG_FILE"
        echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$TG_CONFIG_FILE"
        chmod 600 "$TG_CONFIG_FILE"
        echo -e "\n配置已保存到 $TG_CONFIG_FILE，下次运行可直接使用。"
    fi
}

modify_telegram_config(){
    echo "修改 Telegram 配置:"
    echo "请输入新的 Bot Token:"
    read -r TG_BOT_TOKEN
    echo "请输入新的 Chat ID:"
    read -r TG_CHAT_ID
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$TG_CONFIG_FILE"
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$TG_CONFIG_FILE"
    chmod 600 "$TG_CONFIG_FILE"
    echo "配置已更新。"
}

# ================== 系统信息收集 ==================
collect_system_info(){
    # 系统信息
    hostname=$(hostname)
    os_info=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    kernel_version=$(uname -r)
    cpu_info=$(grep 'model name' /proc/cpuinfo | head -1 | sed -r 's/model name\s*:\s*//')
    cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    cpu_usage_percent=$(top -bn2 | grep "Cpu(s)" | tail -n1 | awk '{print 100-$8"%"}')
    
    mem_total=$(free -m | awk 'NR==2{printf "%.2f", $2/1024}')
    mem_used=$(free -m | awk 'NR==2{printf "%.2f", $3/1024}')
    mem_percent=$(free -m | awk 'NR==2{printf "%.2f", $3*100/$2}')
    mem_info="${mem_used}/${mem_total} GB (${mem_percent}%)"

    swap_total=$(free -m | awk 'NR==3{print $2}')
    swap_used=$(free -m | awk 'NR==3{print $3}')
    if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
      swap_info="未启用"
    else
      swap_percent=$((swap_used*100/swap_total))
      swap_info="${swap_used}MB/${swap_total}MB (${swap_percent}%)"
    fi

    disk_info=$(df -BG / | awk 'NR==2{printf "%.2f/%.2f GB (%s)", $3, $2, $5}')

    ipv4_address=$(curl -s --max-time 5 ipv4.icanhazip.com)
    ipv4_address=${ipv4_address:-无法获取}
    ipv6_address=$(curl -s --max-time 5 ipv6.icanhazip.com)
    ipv6_address=${ipv6_address:-无法获取}

    country=$(curl -s --max-time 3 ipinfo.io/country)
    country=${country:-未知}
    city=$(curl -s --max-time 3 ipinfo.io/city)
    city=${city:-未知}
    isp_info=$(curl -s --max-time 3 ipinfo.io/org)
    isp_info=${isp_info:-未知}

    dns_info=$(grep -E 'nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)

    current_time=$(date "+%Y-%m-%d %I:%M %p")
    runtime=$(awk -F. '{run_days=int($1/86400); run_hours=int(($1%86400)/3600); run_minutes=int(($1%3600)/60); if(run_days>0) printf("%d天 ",run_days); if(run_hours>0) printf("%d时 ",run_hours); printf("%d分\n",run_minutes)}' /proc/uptime)

    # 网络流量统计（选择默认网卡）
    default_iface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    if [ -n "$default_iface" ]; then
        rx_bytes=$(cat /sys/class/net/$default_iface/statistics/rx_bytes)
        tx_bytes=$(cat /sys/class/net/$default_iface/statistics/tx_bytes)

        # 转换为MB/GB
        rx_human=$(awk -v b=$rx_bytes 'BEGIN{if(b<1024) printf "%dB",b; else if(b<1048576) printf "%.2fKB",b/1024; else if(b<1073741824) printf "%.2fMB",b/1048576; else printf "%.2fGB",b/1073741824}')
        tx_human=$(awk -v b=$tx_bytes 'BEGIN{if(b<1024) printf "%dB",b; else if(b<1048576) printf "%.2fKB",b/1024; else if(b<1073741824) printf "%.2fMB",b/1048576; else printf "%.2fGB",b/1073741824}')
        net_traffic="入站: $rx_human, 出站: $tx_human (网卡: $default_iface)"
    else
        net_traffic="无法检测网卡"
    fi

    # 保存输出到临时文件（去掉颜色）
    cat > "$OUTPUT_FILE" <<EOF
VPS 系统信息
------------------------
主机名: $hostname
ISP: $isp_info
系统版本: $os_info
内核版本: $kernel_version
CPU: $cpu_info ($cpu_cores cores)
CPU占用: $cpu_usage_percent
内存: $mem_info
虚拟内存: $swap_info
硬盘占用: $disk_info
公网IPv4: $ipv4_address
公网IPv6: $ipv6_address
DNS: $dns_info
网络流量: $net_traffic
地理位置: $country $city
系统时间: $current_time
运行时长: $runtime
EOF
}

# ================== Telegram 推送 ==================
send_to_telegram(){
    setup_telegram
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "⚠️ 系统信息未生成，无法发送 Telegram"
        return
    fi
    MSG=$(cat "$OUTPUT_FILE")
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="📡 $MSG" >/dev/null 2>&1
    echo -e "${green}VPS 系统信息已发送到 Telegram.${re}"
}

# ================== 彩色终端显示 ==================
show_system_info(){
    collect_system_info
    printf -- "%b%s%b\n" "$green" "====== VPS 系统信息 ======" "$re"
    cat "$OUTPUT_FILE"
}

# ================== 删除临时文件 ==================
delete_temp_file(){
    if [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE"
        echo -e "${green}已删除临时文件 $OUTPUT_FILE${re}"
    else
        echo "临时文件不存在"
    fi
}

# ================== 菜单 ==================
menu(){
    while true; do
        echo ""
        echo -e "${green}====== VPS 管理菜单 ======${re}"
        echo -e "${green}1) 查看 VPS 信息${re}"
        echo -e "${green}2) 发送 VPS 信息到 Telegram${re}"
        echo -e "${green}3) 修改 Telegram 配置${re}"
        echo -e "${green}4) 删除临时文件${re}"
        echo -e "${green}5) 退出${re}"
        echo -ne "${green}请选择操作 [1-5]: ${re}"
        read -r choice
        case $choice in
            1) show_system_info ;;
            2) send_to_telegram ;;
            3) modify_telegram_config ;;
            4) delete_temp_file ;;
            5) exit 0 ;;
            *) echo "无效选择" ;;
        esac
    done
}

# ================== 启动菜单 ==================
menu
