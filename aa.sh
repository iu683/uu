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

# 统一目录到 /opt
BASE_DIR="/opt/rsync_task"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"

CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"
STATUS_FILE="$BASE_DIR/status.log"

mkdir -p "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"
touch "$STATUS_FILE"

#################################
# 首次运行自动安装到本地
#################################
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "${GREEN}首次运行，自动安装到本地...${RESET}"
    mkdir -p "$BASE_DIR"
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    exec "$SCRIPT_PATH"
fi

#################################
# 安装依赖
#################################
install_dep() {
    for p in rsync sshpass curl ssh-keygen ssh-copy-id; do
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
# SSH 密钥管理
#################################
generate_ssh_key() {
    KEY_FILE="$KEY_DIR/id_rsa_rsync"
    PUB_FILE="$KEY_DIR/id_rsa_rsync.pub"
    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${GREEN}生成 SSH 密钥...${RESET}"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" >/dev/null
        echo -e "${GREEN}密钥已生成: $KEY_FILE${RESET}"
    fi
}

setup_ssh_key() {
    local remote_user_host="$1"
    local port="$2"

    PUB_FILE="$KEY_DIR/id_rsa_rsync.pub"

    echo -e "${GREEN}上传公钥到 $remote_user_host ...${RESET}"
    ssh-copy-id -i "$PUB_FILE" -p "$port" "$remote_user_host" >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}公钥上传成功，可免密码登录${RESET}"
    else
        echo -e "${RED}公钥上传失败，请手动检查${RESET}"
    fi
}

#################################
# 任务列表（显示最后一次同步状态）
#################################
list_tasks() {
    [[ ! -s "$CONFIG_FILE" ]] && { echo "暂无任务"; return; }
    awk -F'|' -v status_file="$STATUS_FILE" '{
        task_id=NR;
        name=$1;
        local_dir=$2;
        remote=$3;
        remote_path=$4;
        opt=$6;
        state="未同步";
        while(getline line < status_file) {
            split(line,a,"|");
            if(a[1]==task_id) { state=a[2]; break; }
        }
        printf "%d) %s  %s -> %s [%s] (状态: %s)\n", task_id,name,local_dir,remote_path,opt,state;
    }' "$CONFIG_FILE"
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

    # 自动生成密钥
    generate_ssh_key
    # 自动上传公钥到远程
    setup_ssh_key "$remote" "$port"

    auth="key"
    secret="$KEY_DIR/id_rsa_rsync"

    read -p "rsync参数(-avz): " opt
    opt=${opt:--avz}

    echo "$name|$local|$remote|$remote_path|$port|$opt|$auth|$secret" >> "$CONFIG_FILE"
    echo -e "${GREEN}任务已添加，使用密钥免密码登录${RESET}"
}

#################################
# 删除任务
#################################
delete_task() {
    read -p "编号: " n
    sed -i "${n}d" "$CONFIG_FILE"
    # 删除状态
    sed -i "${n}d" "$STATUS_FILE"
}

#################################
# 压缩同步
#################################
run_task() {
    direction="$1"
    num="$2"

    [[ -z "$num" ]] && read -p "编号: " num

    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && exit 1

    IFS='|' read -r name local remote remote_path port opt auth secret <<< "$task"

    archive_name="sync_temp.tar.gz"
    ssh_opt="-p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [[ "$direction" == "push" ]]; then
        tar -czf "/tmp/$archive_name" -C "$(dirname "$local")" "$(basename "$local")"
        src="/tmp/$archive_name"
        dst="$remote:$remote_path/$archive_name"
    else
        src="$remote:$remote_path/$archive_name"
        dst="/tmp/$archive_name"
    fi

    if [[ "$auth" == "password" ]]; then
        sshpass -p "$secret" rsync $opt -e "ssh $ssh_opt" "$src" "$dst"
    else
        rsync $opt -e "ssh -i $secret $ssh_opt" "$src" "$dst"
    fi

    # pull 时覆盖本地
    if [[ "$direction" == "pull" ]]; then
        rm -rf "$local"
        mkdir -p "$(dirname "$local")"
        tar -xzf "$dst" -C "$(dirname "$local")"
        rm -f "$dst"
    fi

    [[ "$direction" == "push" ]] && rm -f "$src"

    # TG通知
    source "$TG_CONFIG" 2>/dev/null || true
    if [[ $? -eq 0 ]]; then
        send_tg "✅ [$VPS_NAME] 同步成功: $name ($direction)"
        state="成功"
    else
        send_tg "❌ [$VPS_NAME] 同步失败: $name ($direction)"
        state="失败"
    fi

    # 更新状态文件
    sed -i "${num}d" "$STATUS_FILE" 2>/dev/null || true
    echo "$num|$state" >> "$STATUS_FILE"
}

#################################
# cron模式
#################################
if [[ "$1" == "auto" ]]; then
    run_task push "$2"
    exit
fi

#################################
# 定时任务管理（带常用选项）
#################################
schedule_task() {
    read -p "任务编号: " n

    echo -e "${GREEN}请选择定时任务类型:${RESET}"
    echo -e "${GREEN}1) 每天0点${RESET}"
    echo -e "${GREEN}2) 每周一0点${RESET}"
    echo -e "${GREEN}3) 每月1号0点${RESET}"
    echo -e "${GREEN}4) 自定义 cron 表达式${RESET}"
    read -p "选择: " type

    case $type in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "请输入 cron 表达式: " cron ;;
        *) echo -e "${RED}无效选择${RESET}"; return ;;
    esac

    job="$cron /usr/bin/bash $SCRIPT_PATH auto $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"

    crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
    echo -e "${GREEN}定时任务已设置${RESET}"
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
    read -p "$(echo -e ${GREEN} 请选择操作: ${RESET}) " c

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
