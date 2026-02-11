#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

BASE_DIR="/root/rsync_task"
CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"

mkdir -p "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

#################################
# 依赖安装 (Ubuntu/Debian)
#################################
install() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${YELLOW}安装依赖: $1${RESET}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null 2>&1
    fi
}

install rsync
install sshpass


#################################
# Telegram
#################################
send_tg() {
    [[ ! -f "$TG_CONFIG" ]] && return
    source "$TG_CONFIG"
    [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return

    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$1" >/dev/null 2>&1
}

setup_tg() {
    read -p "VPS名称(通知显示): " name
    read -p "Bot Token: " token
    read -p "Chat ID: " chatid

    cat > "$TG_CONFIG" <<EOF
BOT_TOKEN="$token"
CHAT_ID="$chatid"
VPS_NAME="$name"
EOF

    echo -e "${GREEN}TG配置已保存${RESET}"
}


#################################
# 任务列表
#################################
list_tasks() {
    echo -e "${GREEN}已保存任务:${RESET}"
    [[ ! -s "$CONFIG_FILE" ]] && echo "暂无任务" && return
    awk -F'|' '{printf "%d - %s: %s -> %s [%s]\n", NR,$1,$2,$4,$6}' "$CONFIG_FILE"
}


#################################
# 添加任务
#################################
add_task() {
    read -e -p "任务名称: " name
    read -e -p "本地目录: " local_path
    read -e -p "远程目录: " remote_path
    read -e -p "远程用户@IP: " remote
    read -e -p "SSH端口(默认22): " port
    port=${port:-22}

    echo "认证方式: 1密码 2密钥"
    read -e -p "选择: " choice

    if [[ "$choice" == "1" ]]; then
        read -s -p "密码: " password; echo
        auth="password"
        secret="$password"
    else
        read -e -p "密钥路径: " key
        chmod 600 "$key"
        auth="key"
        secret="$key"
    fi

    read -e -p "rsync参数(默认 -avz): " opt
    opt=${opt:--avz}

    echo "$name|$local_path|$remote|$remote_path|$port|$opt|$auth|$secret" >> "$CONFIG_FILE"
    echo -e "${GREEN}任务添加成功${RESET}"
}


#################################
# 删除任务
#################################
delete_task() {
    read -p "任务编号: " num
    sed -i "${num}d" "$CONFIG_FILE"
    echo -e "${GREEN}删除完成${RESET}"
}


#################################
# 执行同步（⭐ 修复：支持cron参数）
#################################
run_task() {
    direction="$1"
    num="$2"

    # 手动模式才提示输入
    if [[ -z "$num" ]]; then
        read -p "任务编号: " num
    fi

    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && { echo "任务不存在"; return; }

    IFS='|' read -r name local remote remote_path port opt auth secret <<< "$task"

    source_path="$local"
    dest_path="$remote:$remote_path"
    [[ "$direction" == "pull" ]] && { source_path="$dest_path"; dest_path="$local"; }

    ssh_opt="-p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    start=$(date '+%F %T')

    if [[ "$auth" == "password" ]]; then
        sshpass -p "$secret" rsync $opt --info=progress2 -e "ssh $ssh_opt" "$source_path" "$dest_path"
    else
        rsync $opt --info=progress2 -e "ssh -i $secret $ssh_opt" "$source_path" "$dest_path"
    fi

    source "$TG_CONFIG" 2>/dev/null || true

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}同步成功${RESET}"
        send_tg "✅ [$VPS_NAME] 同步成功
任务:$name
模式:$direction
时间:$start"
    else
        echo -e "${RED}同步失败${RESET}"
        send_tg "❌ [$VPS_NAME] 同步失败
任务:$name
模式:$direction
时间:$start"
    fi
}


#################################
# 定时任务
#################################
schedule_task() {
    read -p "任务编号: " num
    read -p "cron表达式(例: 0 3 * * *): " cron

    job="$cron /usr/bin/bash $BASE_DIR/rsync_manager.sh auto $num >> $LOG_DIR/cron_$num.log 2>&1 # rsync_$num"

    crontab -l 2>/dev/null | grep -v "# rsync_$num" | { cat; echo "$job"; } | crontab -
    echo -e "${GREEN}定时任务已添加${RESET}"
}

delete_schedule() {
    read -p "任务编号: " num
    crontab -l 2>/dev/null | grep -v "# rsync_$num" | crontab -
    echo -e "${GREEN}已删除定时${RESET}"
}


#################################
# cron自动模式（⭐ 修复关键）
#################################
if [[ "$1" == "auto" ]]; then
    run_task push "$2"
    exit
fi


#################################
# 主菜单
#################################
while true; do
    clear

    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}        Rsync 同步管理器           ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo

    list_tasks
    echo

    echo -e "${GREEN} 1) 添加同步任务${RESET}"
    echo -e "${GREEN} 2) 删除同步任务${RESET}"
    echo -e "${GREEN} 3) 推送同步（本地 → 远程）${RESET}"
    echo -e "${GREEN} 4) 拉取同步（远程 → 本地）${RESET}"
    echo -e "${GREEN} 5) 添加定时任务（cron）${RESET}"
    echo -e "${GREEN} 6) 删除定时任务${RESET}"
    echo -e "${GREEN} 7) Telegram通知 + VPS名称设置${RESET}"
    echo -e "${RED} 0) 退出脚本${RESET}"

    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" c

    case $c in
        1) add_task ;;
        2) delete_task ;;
        3) run_task push ;;
        4) run_task pull ;;
        5) schedule_task ;;
        6) delete_schedule ;;
        7) setup_tg ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac

    read -p "按回车继续..."
done
