#!/bin/bash

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
printf -- "| |/ // ____/ ___/ /  \n"
printf -- "|___//_/     /____/   \n"
printf -- "${re}"

# ================== 系统检测函数 ==================
detect_os(){
  if command -v lsb_release >/dev/null 2>&1; then
    os_info=$(lsb_release -ds)
  elif [ -f /etc/os-release ]; then
    source /etc/os-release
    os_info=$PRETTY_NAME
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
    apt update -y
    for pkg in "${deps[@]}"; do
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "安装 $pkg ..."
        apt install -y "$pkg"
      fi
    done
  elif command -v yum >/dev/null 2>&1; then
    deps=("curl" "vnstat" "redhat-lsb-core" "bc")
    for pkg in "${deps[@]}"; do
      if ! rpm -q "$pkg" >/dev/null 2>&1; then
        echo "安装 $pkg ..."
        yum install -y "$pkg"
      fi
    done
  elif command -v dnf >/dev/null 2>&1; then
    deps=("curl" "vnstat" "redhat-lsb-core" "bc")
    for pkg in "${deps[@]}"; do
      if ! rpm -q "$pkg" >/dev/null 2>&1; then
        echo "安装 $pkg ..."
        dnf install -y "$pkg"
      fi
    done
  elif command -v zypper >/dev/null 2>&1; then
    deps=("curl" "vnstat" "lsb-release" "bc")
    for pkg in "${deps[@]}"; do
      if ! rpm -q "$pkg" >/dev/null 2>&1; then
        echo "安装 $pkg ..."
        zypper install -y "$pkg"
      fi
    done
  fi
  echo -e "\n${green}依赖检查完成！${re}\n"
}

# ================== 执行顺序 ==================
detect_os
install_deps

# ================== 公网IP获取 ==================
ipv4_address=$(curl -s --max-time 5 ipv4.icanhazip.com)
ipv4_address=${ipv4_address:-无法获取}
ipv6_address=$(curl -s --max-time 5 ipv6.icanhazip.com)
ipv6_address=${ipv6_address:-无法获取}

clear

# ================== CPU型号 ==================
cpu_info=$(grep 'model name' /proc/cpuinfo | head -1 | sed -r 's/model name\s*:\s*//')
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
  local usage=0
  if [ $total_diff -ne 0 ]; then
    usage=$((100 * (total_diff - idle_diff) / total_diff))
  fi
  echo "$(awk "BEGIN{printf \"%.1f\", $usage}")%"
}
cpu_usage_percent=$(get_cpu_usage)

# ================== 内存与交换 ==================
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

# ================== 硬盘占用 ==================
disk_info=$(df -BG / | awk 'NR==2{printf "%.2f/%.2f GB (%s)", $3, $2, $5}')

# ================== 地理位置与ISP ==================
country=$(curl -s --max-time 3 ipinfo.io/country)
country=${country:-未知}
city=$(curl -s --max-time 3 ipinfo.io/city)
city=${city:-未知}
isp_info=$(curl -s --max-time 3 ipinfo.io/org)
isp_info=${isp_info:-未知}

# ================== 系统信息 ==================
cpu_arch=$(uname -m)
hostname=$(hostname)
kernel_version=$(uname -r)
congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
os_info=${os_info:-未知}

# ================== 网络流量统计 ==================
format_bytes(){
  local bytes=$1
  local units=("Bytes" "KB" "MB" "GB" "TB")
  local i=0
  while (( $(echo "$bytes > 1024" | bc -l) )) && (( i < ${#units[@]}-1 )); do
    bytes=$(echo "scale=2; $bytes/1024" | bc)
    ((i++))
  done
  echo "$bytes ${units[i]}"
}

get_net_traffic(){
  local rx_total=0 tx_total=0
  while read -r line; do
    iface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    [[ "$iface" =~ ^(lo|docker|veth) ]] && continue
    rx=$(echo "$line" | awk '{print $2}')
    tx=$(echo "$line" | awk '{print $10}')
    rx_total=$((rx_total + rx))
    tx_total=$((tx_total + tx))
  done < <(tail -n +3 /proc/net/dev)
  rx_formatted=$(format_bytes $rx_total)
  tx_formatted=$(format_bytes $tx_total)
  echo "总接收: $rx_formatted"
  echo "总发送: $tx_formatted"
}
net_output=$(get_net_traffic)

# ================== 时间与运行时长 ==================
current_time=$(date "+%Y-%m-%d %I:%M %p")
runtime=$(awk -F. '{run_days=int($1/86400); run_hours=int(($1%86400)/3600); run_minutes=int(($1%3600)/60); if(run_days>0) printf("%d天 ",run_days); if(run_hours>0) printf("%d时 ",run_hours); printf("%d分\n",run_minutes)}' /proc/uptime)

# ================== 动态颜色高亮 ==================
get_usage_color(){
  local value=$1
  if (( $(echo "$value >= 80" | bc -l) )); then
    echo "$red"
  elif (( $(echo "$value >= 50" | bc -l) )); then
    echo "$yellow"
  else
    echo "$green"
  fi
}

cpu_usage_color=$(get_usage_color "${cpu_usage_percent%.*}")
mem_percent_value=$(echo $mem_percent | cut -d. -f1)
mem_usage_color=$(get_usage_color "$mem_percent_value")

# ================== 输出信息 ==================
printf -- "%b系统信息详情%b\n" "$green" "$re"
printf -- "------------------------\n"
printf -- "%b主机名: %b%s%b\n" "$white" "$green" "$hostname" "$re"
printf -- "%b运营商: %b%s%b\n" "$white" "$green" "$isp_info" "$re"
printf -- "------------------------\n"
printf -- "%b系统版本: %b%s%b\n" "$white" "$yellow" "$os_info" "$re"
printf -- "%bLinux版本: %b%s%b\n" "$white" "$yellow" "$kernel_version" "$re"
printf -- "------------------------\n"
printf -- "%bCPU架构: %b%s%b\n" "$white" "$green" "$cpu_arch" "$re"
printf -- "%bCPU型号: %b%s%b\n" "$white" "$green" "$cpu_info" "$re"
printf -- "%bCPU核心数: %b%s%b\n" "$white" "$green" "$cpu_cores" "$re"
printf -- "------------------------\n"
printf -- "%bCPU占用: %b%s%b\n" "$white" "$cpu_usage_color" "$cpu_usage_percent" "$re"
printf -- "%b物理内存: %b%s%b\n" "$white" "$mem_usage_color" "$mem_info" "$re"
printf -- "%b虚拟内存: %b%s%b\n" "$white" "$green" "$swap_info" "$re"
printf -- "%b硬盘占用: %b%s%b\n" "$white" "$green" "$disk_info" "$re"
printf -- "------------------------\n"
printf -- "%b%s%b\n" "$green" "$net_output" "$re"
printf -- "------------------------\n"
printf -- "%b网络拥堵算法: %b%s %s%b\n" "$white" "$green" "$congestion_algorithm" "$queue_algorithm" "$re"
printf -- "------------------------\n"
printf -- "%b公网IPv4地址: %b%s%b\n" "$white" "$yellow" "$ipv4_address" "$re"
printf -- "%b公网IPv6地址: %b%s%b\n" "$white" "$yellow" "$ipv6_address" "$re"
printf -- "------------------------\n"
printf -- "%b地理位置: %b%s %s%b\n" "$white" "$yellow" "$country" "$city" "$re"
printf -- "%b系统时间: %b%s%b\n" "$white" "$yellow" "$current_time" "$re"
printf -- "------------------------\n"
printf -- "%b系统运行时长: %b%s%b\n" "$white" "$green" "$runtime" "$re"
printf -- "\n"
