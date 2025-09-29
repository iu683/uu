#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
white="\033[37m"
re="\033[0m"

# ================== 配置文件 ==================
TG_CONFIG_FILE="/opt/vps/.vps_tg_config"

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
  local deps=("curl" "vnstat" "bc")
  local missing=()

  if ! command -v lsb_release >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1 || command -v apk >/dev/null 2>&1 || command -v pacman >/dev/null 2>&1; then
      deps+=("lsb-release")
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
      deps+=("redhat-lsb-core")
    fi
  fi

  for pkg in "${deps[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return
  fi

  echo -e "${yellow}⚠️ 检测到缺少依赖: ${missing[*]}，开始安装...${re}"

  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y "${missing[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk update
    apk add "${missing[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${missing[@]}"
  else
    echo -e "${red}❌ 未检测到支持的包管理器，请手动安装: ${missing[*]}${re}"
  fi
}

# ================== 公网IP ==================
get_ip_info(){
  ipv4_address=$(curl -s --max-time 5 ipv4.icanhazip.com)
  ipv4_address=${ipv4_address:-无法获取}
  ipv6_address=$(curl -s --max-time 5 ipv6.icanhazip.com)
  ipv6_address=${ipv6_address:-无法获取}
}

# ================== CPU占用 ==================
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

# ================== 网络流量统计 ==================
format_bytes(){
  local bytes=$1
  local units=("B" "KB" "MB" "GB" "TB")
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
  echo "总接收: $rx_formatted | 总发送: $tx_formatted"
}

# ================== 收集系统信息 ==================
collect_system_info(){
  detect_os
  get_ip_info

  cpu_info=$(grep 'model name' /proc/cpuinfo | head -1 | sed -r 's/model name\s*:\s*//')
  cpu_cores=$(grep -c ^processor /proc/cpuinfo)
  cpu_usage_percent=$(get_cpu_usage)

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

  country=$(curl -s --max-time 3 ipinfo.io/country)
  country=${country:-未知}
  city=$(curl -s --max-time 3 ipinfo.io/city)
  city=${city:-未知}
  isp_info=$(curl -s --max-time 3 ipinfo.io/org)
  isp_info=${isp_info:-未知}
  dns_info=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')

  cpu_arch=$(uname -m)
  hostname=$(hostname)
  kernel_version=$(uname -r)
  congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  net_output=$(get_net_traffic)

  current_time=$(date "+%Y-%m-%d %H:%M")
  runtime=$(awk -F. '{run_days=int($1/86400); run_hours=int(($1%86400)/3600); run_minutes=int(($1%3600)/60); if(run_days>0) printf("%d天 ",run_days); if(run_hours>0) printf("%d时 ",run_hours); printf("%d分\n",run_minutes)}' /proc/uptime)

  SYS_INFO=$(cat <<EOF
📡 VPS 系统信息
------------------------
主机名: $hostname
运营商: $isp_info
系统版本: $os_info
内核版本: $kernel_version
CPU架构: $cpu_arch
CPU型号: $cpu_info
CPU核心数: $cpu_cores
CPU占用: $cpu_usage_percent
物理内存: $mem_info
虚拟内存: $swap_info
硬盘占用: $disk_info
= 网络流量统计 =
$net_output
网络拥堵算法: $congestion_algorithm $queue_algorithm
公网IPv4: $ipv4_address
公网IPv6: $ipv6_address
DNS服务器: $dns_info
地理位置: $country $city
系统时间: $current_time
运行时长: $runtime
------------------------
EOF
)
}

# ================== Telegram 配置 ==================
setup_telegram(){
  # 自动创建目录
  mkdir -p "$(dirname "$TG_CONFIG_FILE")"

  echo "第一次运行或缺少配置文件，需要配置 Telegram 参数"
  echo "请输入 Telegram Bot Token:"
  read -r TG_BOT_TOKEN
  echo "请输入 Telegram Chat ID:"
  read -r TG_CHAT_ID
  echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$TG_CONFIG_FILE"
  echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$TG_CONFIG_FILE"
  chmod 600 "$TG_CONFIG_FILE"
  echo -e "\n配置已保存到 $TG_CONFIG_FILE，下次运行可直接使用。"
}

send_to_telegram(){
  if [ ! -f "$TG_CONFIG_FILE" ]; then
    setup_telegram   # 第一次输入 Telegram 配置
  else
    source "$TG_CONFIG_FILE"
  fi

  [ -z "$SYS_INFO" ] && collect_system_info
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "⚠️ Telegram 配置缺失"
    return
  fi

  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$SYS_INFO" >/dev/null 2>&1
  echo -e "${green}✅ 信息已发送到 Telegram${re}"
}

modify_telegram_config(){
  echo "请输入新的 Telegram Bot Token:"
  read -r TG_BOT_TOKEN
  echo "请输入新的 Telegram Chat ID:"
  read -r TG_CHAT_ID
  mkdir -p "$(dirname "$TG_CONFIG_FILE")"
  echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$TG_CONFIG_FILE"
  echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$TG_CONFIG_FILE"
  chmod 600 "$TG_CONFIG_FILE"
  echo -e "${green}✅ Telegram 配置已更新${re}"
}

# ================== 定时任务管理 ==================
setup_cron_job(){
  echo -e "${green}定时任务设置:${re}"
  echo -e "${green}1) 每天发送一次 VPS 信息 (0点)${re}"
  echo -e "${green}2) 每周发送一次 VPS 信息 (周一 0点)${re}"
  echo -e "${green}3) 每月发送一次 VPS 信息 (1号 0点)${re}"
  echo -e "${green}4) 删除当前任务(仅本脚本相关)${re}"
  echo -e "${green}5) 查看当前任务${re}"
  echo -e "${green}6) 返回菜单${re}"
  read -rp "请选择 [1-6]: " cron_choice

  CRON_CMD="bash $0 send"

  case $cron_choice in
    1)
      (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * * $CRON_CMD") | crontab -
      echo -e "${green}✅ 已设置每天 0 点发送一次 VPS 信息${re}"
      ;;
    2)
      (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * 1 $CRON_CMD") | crontab -
      echo -e "${green}✅ 已设置每周一 0 点发送一次 VPS 信息${re}"
      ;;
    3)
      (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 1 * * $CRON_CMD") | crontab -
      echo -e "${green}✅ 已设置每月 1 日 0 点发送一次 VPS 信息${re}"
      ;;
    4)
      crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
      echo -e "${red}❌ 已删除本脚本相关的定时任务${re}"
      ;;
    5)
      echo -e "${yellow}当前已配置的定时任务:${re}"
      crontab -l 2>/dev/null | grep "$CRON_CMD" || echo "⚠️ 没有找到和本脚本相关的定时任务"
      ;;
    6) return ;;
    *) echo "无效选择" ;;
  esac
}

# ================== 返回菜单等待 ==================
pause_return(){
  read -rp "👉 按回车返回菜单..." temp
}

# ================== 菜单 ==================
menu(){
  while true; do
    echo ""
    echo -e "${green}====== VPS 管理菜单 ======${re}"
    echo -e "${green}1) 查看 VPS 信息${re}"
    echo -e "${green}2) 发送 VPS 信息到 Telegram${re}"
    echo -e "${green}3) 修改 Telegram 配置${re}"
    echo -e "${green}4) 设置定时任务${re}"
    echo -e "${green}5) 退出${re}"
    read -rp "请选择操作 [1-5]: " choice
    case $choice in
      1) collect_system_info; echo "$SYS_INFO"; pause_return ;;
      2) 
        collect_system_info
        send_to_telegram  # 第一次输入配置后立即发送
        pause_return
        ;;
      3) modify_telegram_config; pause_return ;;
      4) setup_cron_job; pause_return ;;
      5) exit 0 ;;
      *) echo "无效选择"; pause_return ;;
    esac
  done
}

# ================== 命令行模式 ==================
if [ "$1" == "send" ]; then
  send_to_telegram
  exit 0
fi

# ================== 脚本入口 ==================
install_deps
menu
