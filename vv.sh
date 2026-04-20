#!/bin/bash
# 支持 Debian/Ubuntu, RHEL/CentOS, Alpine, openSUSE

# ================== 颜色定义 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
white="\033[37m"
re="\033[0m"

# ================== ASCII VPS Logo ==================
printf -- "${red}"
printf -- " _    __ ____   _____ \n"
printf -- "| |  / // __ \\ / ___/ \n"
printf -- "| | / // /_/ / \\__ \\  \n"
printf -- "| |/ // ____/ __/  /  \n"
printf -- "|___//_/     /____/   \n"
printf -- "${re}"

# ================== 系统检测函数 ==================
detect_os(){
  if [ -f /etc/os-release ]; then
    source /etc/os-release
    os_info=$PRETTY_NAME
  elif command -v lsb_release >/dev/null 2>&1; then
    os_info=$(lsb_release -ds)
  elif [ -f /etc/debian_version ]; then
    os_info="Debian $(cat /etc/debian_version)"
  elif [ -f /etc/redhat-release ]; then
    os_info=$(cat /etc/redhat-release)
  else
    os_info="未知系统"
  fi
}

# ================== 依赖安装函数 ==================
install_deps(){
  if command -v apt >/dev/null 2>&1; then
    deps=("curl" "vnstat" "lsb-release" "bc")
    apt update -y >/dev/null 2>&1
    for pkg in "${deps[@]}"; do
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        apt install -y "$pkg" >/dev/null 2>&1
      fi
    done
  elif command -v apk >/dev/null 2>&1; then
    deps=("curl" "vnstat" "bc" "bash")
    apk update >/dev/null 2>&1
    for pkg in "${deps[@]}"; do
      apk add "$pkg" >/dev/null 2>&1
    done
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    pkg_mgr=$(command -v dnf || echo "yum")
    deps=("curl" "vnstat" "redhat-lsb-core" "bc")
    for pkg in "${deps[@]}"; do
      $pkg_mgr install -y "$pkg" >/dev/null 2>&1
    done
  fi
}

# 执行初始化
detect_os
install_deps

# ================== 公网IP获取 ==================
ipv4_address=$(curl -s --max-time 5 ipv4.icanhazip.com || echo "无法获取")
ipv6_address=$(curl -s --max-time 5 ipv6.icanhazip.com || echo "无法获取")

# ================== 格式化 bc 输出 (核心修复) ==================
# 补全 .3 -> 0.3 的函数
fix_number() {
  local num=$1
  if [[ $num == .* ]]; then echo "0$num"; elif [[ $num == -.* ]]; then echo "-0${num#*-}"; else echo "$num"; fi
}

# ================== CPU信息 ==================
cpu_info=$(grep 'model name' /proc/cpuinfo | head -1 | sed -r 's/model name\s*:\s*//')
[ -z "$cpu_info" ] && cpu_info=$(uname -p)
cpu_cores=$(grep -c ^processor /proc/cpuinfo)

# ================== CPU占用率 ==================
get_cpu_usage(){
  local cpu1=($(head -n1 /proc/stat))
  local idle1=${cpu1[4]}
  local total1=0
  for val in "${cpu1[@]:1}"; do total1=$((total1 + val)); done
  sleep 1
  local cpu2=($(head -n1 /proc/stat))
  local idle2=${cpu2[4]}
  local total2=0
  for val in "${cpu2[@]:1}"; do total2=$((total2 + val)); done
  local idle_diff=$((idle2 - idle1))
  local total_diff=$((total2 - total1))
  if [ $total_diff -eq 0 ]; then
    echo "0.0"
  else
    usage=$(echo "scale=1; 100 * ($total_diff - $idle_diff) / $total_diff" | bc)
    fix_number "$usage"
  fi
}
cpu_usage_val=$(get_cpu_usage)
cpu_usage_percent="${cpu_usage_val}%"

# ================== 内存与交换 ==================
mem_total_k=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_free_k=$(grep MemFree /proc/meminfo | awk '{print $2}')
mem_buff_k=$(grep Buffers /proc/meminfo | awk '{print $2}')
mem_cache_k=$(grep ^Cached /proc/meminfo | awk '{print $2}')
mem_used_k=$((mem_total_k - mem_free_k - mem_buff_k - mem_cache_k))

mem_total_gb=$(fix_number "$(echo "scale=2; $mem_total_k/1024/1024" | bc)")
mem_used_gb=$(fix_number "$(echo "scale=2; $mem_used_k/1024/1024" | bc)")
mem_percent_val=$(fix_number "$(echo "scale=2; $mem_used_k*100/$mem_total_k" | bc)")
mem_info="${mem_used_gb}/${mem_total_gb} GB (${mem_percent_val}%)"

swap_total_k=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
swap_free_k=$(grep SwapFree /proc/meminfo | awk '{print $2}')
if [ -z "$swap_total_k" ] || [ "$swap_total_k" -eq 0 ]; then
  swap_info="未启用"
else
  swap_used_k=$((swap_total_k - swap_free_k))
  swap_percent=$((swap_used_k*100/swap_total_k))
  swap_info="$(($swap_used_k/1024))MB/$(($swap_total_k/1024))MB (${swap_percent}%)"
fi

# ================== 网络流量统计 ==================
format_bytes(){
  local bytes=${1:-0}
  if (( $(echo "$bytes < 1024" | bc -l) )); then
    echo "${bytes} B"
  elif (( $(echo "$bytes < 1048576" | bc -l) )); then
    echo "$(fix_number "$(echo "scale=2; $bytes/1024" | bc)") KB"
  elif (( $(echo "$bytes < 1073741824" | bc -l) )); then
    echo "$(fix_number "$(echo "scale=2; $bytes/1048576" | bc)") MB"
  else
    echo "$(fix_number "$(echo "scale=2; $bytes/1073741824" | bc)") GB"
  fi
}

get_net_traffic(){
  local rx_total=0 tx_total=0
  while read -r line; do
    iface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    [[ "$iface" =~ ^(lo|docker|veth|br-|flannel) ]] && continue
    rx=$(echo "$line" | awk '{print $2}')
    tx=$(echo "$line" | awk '{print $10}')
    rx_total=$((rx_total + rx))
    tx_total=$((tx_total + tx))
  done < <(tail -n +3 /proc/net/dev)
  echo "总接收: $(format_bytes $rx_total)"
  echo "总发送: $(format_bytes $tx_total)"
}

# ================== 其他系统信息 ==================
disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
geo_data=$(curl -s --max-time 3 http://ip-api.com/json/)
country=$(echo "$geo_data" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
city=$(echo "$geo_data" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
isp_info=$(echo "$geo_data" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
cpu_arch=$(uname -m)
hostname=$(hostname)
kernel_version=$(uname -r)
congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
net_output=$(get_net_traffic)
up_sec=$(cut -d. -f1 /proc/uptime)
runtime="$((up_sec/86400))天 $(((up_sec%86400)/3600))时 $(((up_sec%3600)/60))分"

# ================== 动态颜色高亮 ==================
get_usage_color(){
  local val=$1
  if [ -z "$val" ] || [ "$val" == "0" ]; then echo "$green"; return; fi
  # 使用 bc -l 处理带小数点的比较
  local res=$(echo "$val >= 80" | bc -l)
  if [ "$res" -eq 1 ]; then echo "$red"
  elif [ "$(echo "$val >= 50" | bc -l)" -eq 1 ]; then echo "$yellow"
  else echo "$green"; fi
}
cpu_usage_color=$(get_usage_color "$cpu_usage_val")
mem_usage_color=$(get_usage_color "$mem_percent_val")

# ================== 输出 ==================
clear
printf -- "%b系统信息详情%b\n" "$green" "$re"
printf -- "------------------------\n"
printf -- "%b主机名: %b%s%b\n" "$white" "$green" "$hostname" "$re"
printf -- "%b运营商: %b%s%b\n" "$white" "$green" "${isp_info:-未知}" "$re"
printf -- "------------------------\n"
printf -- "%b系统版本: %b%s%b\n" "$white" "$yellow" "$os_info" "$re"
printf -- "%b内核版本: %b%s%b\n" "$white" "$yellow" "$kernel_version" "$re"
printf -- "------------------------\n"
printf -- "%bCPU架构: %b%s%b\n" "$white" "$green" "$cpu_arch" "$re"
printf -- "%bCPU型号: %b%s%b\n" "$white" "$green" "$cpu_info" "$re"
printf -- "%bCPU核心: %b%s%b\n" "$white" "$green" "$cpu_cores" "$re"
printf -- "------------------------\n"
printf -- "%bCPU占用: %b%s%b\n" "$white" "$cpu_usage_color" "$cpu_usage_percent" "$re"
printf -- "%b物理内存: %b%s%b\n" "$white" "$mem_usage_color" "$mem_info" "$re"
printf -- "%b虚拟内存: %b%s%b\n" "$white" "$green" "$swap_info" "$re"
printf -- "%b硬盘占用: %b%s%b\n" "$white" "$green" "$disk_info" "$re"
printf -- "------------------------\n"
printf -- "%b%s%b\n" "$green" "$net_output" "$re"
printf -- "------------------------\n"
printf -- "%b拥塞算法: %b%s %s%b\n" "$white" "$green" "$congestion_algorithm" "$queue_algorithm" "$re"
printf -- "------------------------\n"
printf -- "%bIPv4地址: %b%s%b\n" "$white" "$yellow" "$ipv4_address" "$re"
printf -- "%bIPv6地址: %b%s%b\n" "$white" "$yellow" "$ipv6_address" "$re"
printf -- "------------------------\n"
printf -- "%b地理位置: %b%s %s%b\n" "$white" "$yellow" "$country" "$city" "$re"
printf -- "%b系统时间: %b%s%b\n" "$white" "$yellow" "$(date "+%Y-%m-%d %H:%M")" "$re"
printf -- "------------------------\n"
printf -- "%b运行时长: %b%s%b\n" "$white" "$green" "$runtime" "$re"
printf -- "\n"
