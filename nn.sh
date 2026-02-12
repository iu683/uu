#!/bin/bash

# ================== 颜色定义 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
white="\033[37m"
re="\033[0m"

# ================== 基础配置 ==================
SCRIPT_PATH="/opt/vpsdocker/docker_info.sh"
TG_CONFIG_FILE="/opt/vpsdocker/.vps_tgd_config"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"

# ================== 下载或更新脚本 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
}

# ================== 工具函数 ==================

# 兼容 column（没有也能跑）
print_table(){
  if command -v column >/dev/null 2>&1; then
    column -t
  else
    cat
  fi
}

safe_text(){
  sed 's/[&]/and/g'
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

# ================== Docker 信息收集 ==================
collect_docker_info(){

  if ! command -v docker >/dev/null 2>&1; then
    SYS_INFO="❌ 未安装 Docker"
    return
  fi

  container_count=$(docker ps -q | wc -l)

  running=$(docker ps --format '{{.Names}} ({{.Status}})' | sed 's/^/▶ /')
  [ -z "$running" ] && running="无"

  container_stats=$(docker stats --no-stream \
    --format "▶ {{.Name}} | CPU {{.CPUPerc}} | MEM {{.MemUsage}} | NET {{.NetIO}}")
  [ -z "$container_stats" ] && container_stats="无"

  images=$(docker images --format '📦 {{.Repository}}:{{.Tag}} | {{.Size}}' | print_table)
  [ -z "$images" ] && images="无"

  current_time=$(date "+%Y-%m-%d %H:%M")

  SYS_INFO=$(cat <<EOF
🐳 Docker 信息推送
========================
容器数量: $container_count

运行中容器:
$running

容器资源占用:
$container_stats

镜像列表:
$images

系统时间: $current_time
========================
EOF
)
}



# ================== Telegram 配置 ==================
setup_telegram(){
  mkdir -p "$(dirname "$TG_CONFIG_FILE")"
  echo "第一次运行或缺少配置文件，需要配置 Telegram 参数"

  read -rp "请输入 Telegram Bot Token: " TG_BOT_TOKEN
  read -rp "请输入 Telegram Chat ID: " TG_CHAT_ID
  read -rp "请输入服务器名称（用于 Telegram 消息显示）: " SERVER_NAME

  cat > "$TG_CONFIG_FILE" <<EOC
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
EOC

  chmod 600 "$TG_CONFIG_FILE"
  echo -e "\n配置已保存到 $TG_CONFIG_FILE，下次运行可直接使用。"
}

modify_telegram_config(){
  echo "修改 Telegram 配置："

  read -rp "请输入新的 Telegram Bot Token: " TG_BOT_TOKEN
  read -rp "请输入新的 Telegram Chat ID: " TG_CHAT_ID
  read -rp "请输入服务器名称（用于 Telegram 消息显示）: " SERVER_NAME

  mkdir -p "$(dirname "$TG_CONFIG_FILE")"
  cat > "$TG_CONFIG_FILE" <<EOC
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
EOC

  chmod 600 "$TG_CONFIG_FILE"
  echo -e "${green}✅ Telegram 配置已更新${re}"
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

  # 在消息开头加服务器名称
  MSG="[$SERVER_NAME]$SYS_INFO"

  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$MSG" >/dev/null 2>&1

  if [ "$first_run" -eq 1 ]; then
    echo -e "${green}✅ 配置已保存，并已发送第一次 Docker 信息到 Telegram${re}"
  else
    echo -e "${green}✅ 信息已发送到 Telegram${re}"
  fi
}

# ================== 定时任务管理 ==================
setup_cron_job(){
  enable_cron_service

  echo -e "${green}定时任务设置:${re}"
  echo -e "${green}1) 每天发送一次 (0点)${re}"
  echo -e "${green}2) 每周发送一次 (周一 0点)${re}"
  echo -e "${green}3) 每月发送一次 (1号 0点)${re}"
  echo -e "${green}4) 每5分钟一次${re}"
  echo -e "${green}5) 每10分钟一次${re}"
  echo -e "${green}6) 自定义时间 (Cron表达式)${re}"
  echo -e "${green}7) 删除当前任务${re}"
  echo -e "${green}8) 查看当前任务${re}"
  echo -e "${green}0) 返回菜单${re}"

  read -rp "$(echo -e ${green}请选择: ${re})" cron_choice

  CRON_CMD="bash $SCRIPT_PATH send"

  case $cron_choice in
    1) CRON_TIME="0 0 * * *" ;;
    2) CRON_TIME="0 0 * * 1" ;;
    3) CRON_TIME="0 0 1 * *" ;;
    4) CRON_TIME="*/5 * * * *" ;;
    5) CRON_TIME="*/10 * * * *" ;;

    6)
      echo -e "${yellow}请输入 Cron 表达式${re}"
      echo -e "${yellow}格式: 分 时 日 月 周${re}"
      echo -e "${yellow}示例: 30 3 * * * (每天03:30)${re}"
      read -rp "Cron: " CRON_TIME

      count=$(echo "$CRON_TIME" | awk '{print NF}')
      if [ "$count" -ne 5 ]; then
        echo -e "${red}❌ 格式错误，必须5段${re}"
        return
      fi
      ;;

    7)
      crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
      echo -e "${red}❌ 已删除任务${re}"
      return
      ;;

    8)
      echo -e "${yellow}当前任务:${re}"
      crontab -l 2>/dev/null | grep "$CRON_CMD" || echo "暂无任务"
      return
      ;;

    0) return ;;
    *) echo -e "${red}无效选择${re}"; return ;;
  esac

  # 覆盖旧任务
  (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "$CRON_TIME $CRON_CMD") | crontab -

  echo -e "${green}✅ 定时任务设置成功: $CRON_TIME${re}"
}


pause_return(){
  read -p "$(echo -e ${green}按回车返回菜单${re}) " temp
}

# ================== 卸载脚本 ==================
uninstall_script(){
    echo -e "${yellow}正在卸载脚本、配置及定时任务...${re}"

    CRON_CMD="bash $SCRIPT_PATH send"

    # 清理定时任务（存在才删除）
    if crontab -l >/dev/null 2>&1; then
        crontab -l | grep -v "$CRON_CMD" | crontab -
    fi

    # 删除文件和目录
    rm -rf "$SCRIPT_PATH" "$TG_CONFIG_FILE" /opt/vpsdocker

    echo -e "${green}✅ 卸载完成，相关数据和定时任务已删除${re}"
    exit 0
}


# ================== 菜单 ==================
menu(){
  while true; do
    clear
    echo -e "${green}====== Docker信息管理菜单 ======${re}"
    echo -e "${green}1) 查看Docker信息${re}"
    echo -e "${green}2) 发送Docker信息到Telegram${re}"
    echo -e "${green}3) 修改Telegram配置${re}"
    echo -e "${green}4) 设置定时任务${re}"
    echo -e "${green}5) 卸载${re}"
    echo -e "${green}0) 退出${re}"
    read -p "$(echo -e ${green}请选择: ${re})" choice
    case $choice in
      1) collect_docker_info; echo "$SYS_INFO"; pause_return ;;
      2) collect_docker_info; send_to_telegram; pause_return ;;
      3) modify_telegram_config; pause_return ;;
      4) setup_cron_job; pause_return ;;
      5) uninstall_script ;;
      0) exit 0 ;;
      *) echo -e "${red}无效选择${re}"; pause_return ;;
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
