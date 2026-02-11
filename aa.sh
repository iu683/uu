#!/bin/bash
set -e

#################################
# 基础配置
#################################

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"

BASE_DIR="/root/rsync_task"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"

CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"

mkdir -p "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

#################################
# ⭐ 首次运行自动安装到本地
#################################
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "${GREEN}首次运行，自动安装到本地...${RESET}"
    mkdir -p "$BASE_DIR"
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    exec "$SCRIPT_PATH"
fi

#################################
# 依赖安装
#################################
install_dep() {
    for p in rsync sshpass curl; do
        if ! command -v $p &>/dev/null; then
            echo -e "${YELLOW}安装依赖: $p${RESET}"
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y $p >/dev/null 2>&1
        fi
    done
}
install_dep

#################################
# Telegram
#################################
send_tg() {
    [[ ! -f "$TG_CONFIG" ]] && return
    source "$TG_CONFIG"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$1" >/dev/null 2>&1
}

setup_tg() {
    read -p "VPS名称: " name
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
    [[ ! -s "$CONFIG_FILE" ]] && { echo "暂无任务"; return; }
    awk -F'|' '{printf "%d) %s  %s -> %s [%s]\n",NR,$1,$2,$4,$6}' "$CONFIG_FILE"
}

#################################
# 添加任务
#################################
add_task() {
    read -p "任务名称: " name
    read -p "本地目录: " local
    read -p "远程目录: " remote_path
    read -p "远程用户@IP: " remote
    read -p "端口(默认22): " port
    port=${port:-22}

    echo "认证方式: 1密码 2密钥"
    read -p "选择: " c

    if [[ $c == 1 ]]; then
        read -s -p "密码: " secret; echo
        auth="password"
    else
        read -p "密钥路径: " secret
        chmod 600 "$secret"
        auth="key"
    fi

    read -p "rsync参数(-avz): " opt
    opt=${opt:--avz}

    echo "$name|$local|$remote|$remote_path|$port|$opt|$auth|$secret" >> "$CONFIG_FILE"
}

#################################
# 删除任务
#################################
delete_task() {
    read -p "编号: " n
    sed -i "${n}d" "$CONFIG_FILE"
}

#################################
# 同步执行（支持cron）
#################################
run_task() {
    direction="$1"
    num="$2"

    [[ -z "$num" ]] && read -p "编号: " num

    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && exit 1

    IFS='|' read -r name local remote remote_path port opt auth secret <<< "$task"

    src="$local"
    dst="$remote:$remote_path"
    [[ "$direction" == "pull" ]] && { src="$dst"; dst="$local"; }

    ssh_opt="-p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [[ "$auth" == "password" ]]; then
        sshpass -p "$secret" rsync $opt -e "ssh $ssh_opt" "$src" "$dst"
    else
        rsync $opt -e "ssh -i $secret $ssh_opt" "$src" "$dst"
    fi

    source "$TG_CONFIG" 2>/dev/null || true

    if [[ $? -eq 0 ]]; then
        send_tg "✅ [$VPS_NAME] 同步成功: $name ($direction)"
    else
        send_tg "❌ [$VPS_NAME] 同步失败: $name ($direction)"
    fi
}

#################################
# cron模式
#################################
if [[ "$1" == "auto" ]]; then
    run_task push "$2"
    exit
fi

#################################
# 定时
#################################
schedule_task() {
    read -p "任务编号: " n
    read -p "cron表达式: " cron

    job="$cron /usr/bin/bash $SCRIPT_PATH auto $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"

    crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
}

delete_schedule() {
    read -p "编号: " n
    crontab -l 2>/dev/null | grep -v "# rsync_$n" | crontab -
}

#################################
# 更新 & 卸载
#################################
update_self() {
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "已更新"
}

uninstall_self() {
    crontab -l 2>/dev/null | grep -v "rsync_" | crontab - || true
    rm -rf "$BASE_DIR"
    echo "已卸载"
    exit
}

#################################
# 菜单
#################################
while true; do
    clear
    echo -e "${GREEN}===== Rsync 同步管理器 =====${RESET}"
    list_tasks
    echo
    echo -e "${GREEN} 1) 添加同步任务${RESET}"
    echo -e "${GREEN} 2) 删除同步任务${RESET}"
    echo -e "${GREEN} 3) 推送同步${RESET}"
    echo -e "${GREEN} 4) 拉取同步${RESET}"
    echo -e "${GREEN} 5) 添加定时任务${RESET}"
    echo -e "${GREEN} 6) 删除定时任务${RESET}"
    echo -e "${GREEN} 7) Telegram设置${RESET}"
    echo -e "${GREEN} 8) 更新脚本${RESET}"
    echo -e "${GREEN} 9) 卸载脚本${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择操作: ${RESET}) " c

    case $c in
        1) add_task ;;
        2) delete_task ;;
        3) run_task push ;;
        4) run_task pull ;;
        5) schedule_task ;;
        6) delete_schedule ;;
        7) setup_tg ;;
        8) update_self ;;
        9) uninstall_self ;;
        0) exit ;;
    esac

    read -p "回车继续..."
done
