#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
white="\033[37m"
re="\033[0m"

# ================== 基础配置 ==================
SCRIPT_PATH="/opt/vpsd/docker_info.sh"
TG_CONFIG_FILE="/opt/vpsd/.vps_tgd_config"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"

# ================== 下载或更新脚本 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
}

# ================== 确保 cron 服务已开启 ==================
enable_cron_service(){
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "^cron.service"; then
      systemctl enable --now cron >/dev/null 2>&1
    elif systemctl list-unit-files | grep -q "^crond.service"; then
      systemctl enable --now crond >/dev/null 2>&1
    fi
  elif command -v service >/dev/null 2>&1; then
    service cron start 2>/dev/null || service crond start 2>/dev/null
  fi
}

# ================== Docker 信息 ==================
collect_docker_info(){
  if ! command -v docker >/dev/null 2>&1; then
    DOCKER_INFO="❌ *未检测到 Docker*"
    return
  fi

  docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  container_count=$(docker ps -q | wc -l)
  all_container_count=$(docker ps -aq | wc -l)

  # 容器资源占用（按内存排序）
  container_stats=$(docker stats --no-stream --format "{{.Name}} | CPU: {{.CPUPerc}} | MEM: {{.MemUsage}} | NET: {{.NetIO}}" \
    | sort -k6 -h 2>/dev/null)
  [ -z "$container_stats" ] && container_stats="暂无运行中的容器"

  # 镜像信息（大小）
  images_info=$(docker images --format "{{.Repository}}:{{.Tag}} ({{.Size}})")
  [ -z "$images_info" ] && images_info="暂无镜像"

  # 磁盘占用
  disk_usage=$(docker system df --format "Images: {{.Images}} ({{.Size}}) | Containers: {{.Containers}} ({{.Size}}) | Volumes: {{.Volumes}} ({{.Size}})" 2>/dev/null)

  DOCKER_INFO=$(cat <<EOF
🐳 *Docker 信息*
━━━━━━━━━━━━━━━
📦 版本: \`$docker_version\`
📊 运行中容器: *$container_count*
📊 总容器数: *$all_container_count*

📋 *容器资源占用 (按内存排序)*
\`\`\`
$container_stats
\`\`\`

🖼️ *镜像列表*
\`\`\`
$images_info
\`\`\`

💾 *磁盘占用*
$disk_usage
━━━━━━━━━━━━━━━
EOF
)
}



# ================== Telegram 配置 ==================
setup_telegram(){
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
  local first_run=0
  if [ ! -f "$TG_CONFIG_FILE" ]; then
    first_run=1
    setup_telegram
  fi

  source "$TG_CONFIG_FILE"
  [ -z "$SYS_INFO" ] && collect_docker_info

  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "⚠️ Telegram 配置缺失"
    return
  fi

  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$SYS_INFO" >/dev/null 2>&1

  if [ "$first_run" -eq 1 ]; then
    echo -e "${green}✅ 配置已保存，并已发送第一次 Docker 信息到 Telegram${re}"
  else
    echo -e "${green}✅ 信息已发送到 Telegram${re}"
  fi
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
  echo -e "${green}1) 每天发送一次 Docker 信息 (0点)${re}"
  echo -e "${green}2) 每周发送一次 Docker 信息 (周一 0点)${re}"
  echo -e "${green}3) 每月发送一次 Docker 信息 (1号 0点)${re}"
  echo -e "${green}4) 删除当前任务(仅本脚本相关)${re}"
  echo -e "${green}5) 查看当前任务${re}"
  echo -e "${green}6) 返回菜单${re}"
  read -rp "请选择 [1-6]: " cron_choice

  CRON_CMD="bash $SCRIPT_PATH send"

  case $cron_choice in
    1) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * * $CRON_CMD") | crontab -
       echo -e "${green}✅ 已设置每天 0 点发送一次 Docker 信息${re}" ;;
    2) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * 1 $CRON_CMD") | crontab -
       echo -e "${green}✅ 已设置每周一 0 点发送一次 Docker 信息${re}" ;;
    3) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 1 * * $CRON_CMD") | crontab -
       echo -e "${green}✅ 已设置每月 1 日 0 点发送一次 Docker 信息${re}" ;;
    4) crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
       echo -e "${red}❌ 已删除本脚本相关的定时任务${re}" ;;
    5) echo -e "${yellow}当前已配置的定时任务:${re}"
       crontab -l 2>/dev/null | grep "$CRON_CMD" || echo "没有找到和本脚本相关的定时任务" ;;
    6) return ;;
    *) echo "无效选择" ;;
  esac
}

pause_return(){
  read -rp "👉 按回车返回菜单..." temp
}

# ================== 卸载脚本 ==================
uninstall_script(){
    echo -e "${yellow}即将卸载脚本及配置和定时任务${re}"
    read -rp "确认卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        CRON_CMD="bash $SCRIPT_PATH send"
        crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
        rm -f "$SCRIPT_PATH"
        rm -f "$TG_CONFIG_FILE"
        rm -rf /opt/vpsd
        echo -e "${green}✅ 卸载完成,相关数据和定时任务已删除${re}"
        exit 0
    else
        echo "取消卸载"
    fi
}

# ================== 菜单 ==================
menu(){
  while true; do
    clear
    echo -e "${green}====== Docker 信息管理菜单 ======${re}"
    echo -e "${green}1) 查看 Docker 信息${re}"
    echo -e "${green}2) 发送 Docker 信息到 Telegram${re}"
    echo -e "${green}3) 修改 Telegram 配置${re}"
    echo -e "${green}4) 设置定时任务${re}"
    echo -e "${green}5) 卸载脚本${re}"
    echo -e "${green}0) 退出${re}"
    read -rp "请选择操作: " choice
    case $choice in
      1) collect_docker_info; echo "$SYS_INFO"; pause_return ;;
      2) collect_docker_info; send_to_telegram; pause_return ;;
      3) modify_telegram_config; pause_return ;;
      4) setup_cron_job; pause_return ;;
      5) uninstall_script ;;
      0) exit 0 ;;
      *) echo "无效选择"; pause_return ;;
    esac
  done
}

# ================== 命令行模式 ==================
if [ "$1" == "send" ]; then
  collect_docker_info
  send_to_telegram
  exit 0
fi

# ================== 脚本入口 ==================
enable_cron_service
download_script
menu
