#!/bin/bash
set -e

#################################
# 环境变量 & 配置
#################################
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

BASE_DIR="/opt/rsync_task"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/qq.sh"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
TG_CONFIG="$BASE_DIR/.tg.conf"
BIN_LINK_DIR="/usr/local/bin"

mkdir -p "$BASE_DIR" "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

#################################
# 安装依赖
#################################
install_dep() {
    for p in rsync ssh sshpass curl tar; do
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
    read -p "VPS名称: " VPS_NAME
    read -p "Bot Token: " BOT_TOKEN
    read -p "Chat ID: " CHAT_ID
    cat > "$TG_CONFIG" <<EOF
VPS_NAME="$VPS_NAME"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
EOF
    chmod 600 "$TG_CONFIG"
    echo -e "${GREEN}TG配置已保存${RESET}"
}

#################################
# SSH 密钥管理
#################################
generate_and_setup_ssh() {
    local remote="$1"
    local port="$2"
    KEY_FILE="$KEY_DIR/id_rsa_rsync"
    PUB_FILE="$KEY_FILE.pub"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}未检测到本地 SSH 密钥，正在生成...${RESET}"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
        echo -e "${GREEN}✅ 本地 SSH 密钥生成完成${RESET}"
    fi

    PUBKEY_CONTENT=$(cat "$PUB_FILE")
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${remote#*@}" >/dev/null 2>&1

    echo -e "${YELLOW}第一次连接需要输入远程密码${RESET}"
    ssh -p "$port" "$remote" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    ssh -p "$port" "$remote" "grep -Fxq '$PUBKEY_CONTENT' ~/.ssh/authorized_keys || echo '$PUBKEY_CONTENT' >> ~/.ssh/authorized_keys"

    ssh -i "$KEY_FILE" -p "$port" "$remote" "echo 2>&1" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✅ 公钥写入成功，可免密码登录 $remote${RESET}"
    else
        echo -e "${RED}❌ 公钥写入失败，请检查 SSH${RESET}"
    fi
}

#################################
# 任务管理
#################################
list_tasks() {
    [[ ! -s "$CONFIG_FILE" ]] && { echo "暂无任务"; return; }
    awk -F'|' '{printf "%d) %s  %s -> %s [%s]\n",NR,$1,$2,$3,$5}' "$CONFIG_FILE"
}

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
        generate_and_setup_ssh "$remote" "$port"
        secret="$KEY_DIR/id_rsa_rsync"
        auth="key"
    fi

    echo "$name|$local|$remote|$remote_path|$port|$auth|$secret" >> "$CONFIG_FILE"
}

delete_task() {
    read -p "编号: " n
    sed -i "${n}d" "$CONFIG_FILE"
}

#################################
# 压缩同步
#################################
run_task() {
    direction="$1"
    num="$2"

    # 手动模式下，如果没有编号就让用户输入
    if [[ -z "$num" ]]; then
        read -p "编号: " num
    fi

    task=$(sed -n "${num}p" "$CONFIG_FILE" | tr -d '\r\n')
    [[ -z "$task" ]] && { echo -e "${RED}❌ 任务编号 $num 不存在${RESET}"; return; }

    IFS='|' read -r name local remote remote_path port auth secret <<< "$task"
    archive="/tmp/sync_task_${name}.tar.gz"

        if [[ "$direction" == "push" ]]; then
        tar -czf "$archive" -C "$(dirname "$local")" "$(basename "$local")"

        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" ssh -p $port $remote "mkdir -p $remote_path"
            sshpass -p "$secret" rsync -avz -e "ssh -p $port" "$archive" "$remote:$remote_path/"
        else
            ssh -i "$secret" -p $port $remote "mkdir -p $remote_path"
            rsync -avz -e "ssh -i $secret -p $port" "$archive" "$remote:$remote_path/"
        fi
        echo -e "${GREEN}✅ [$name] 已推送压缩包${RESET}"
        # Telegram 通知修改
        send_tg "[$VPS_NAME] 任务 [$name] 同步完成 ✅ (推送)"
    else
        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" rsync -avz -e "ssh -p $port" "$remote:$remote_path/$(basename "$archive")" "/tmp/"
        else
            rsync -avz -e "ssh -i $secret -p $port" "$remote:$remote_path/$(basename "$archive")" "/tmp/"
        fi
        rm -rf "$local"
        mkdir -p "$local"
        tar -xzf "/tmp/$(basename "$archive")" -C "$(dirname "$local")"
        rm -f "/tmp/$(basename "$archive")"
        echo -e "${GREEN}✅ [$name] 已拉取并覆盖本地${RESET}"
        # Telegram 通知修改
        send_tg "[$VPS_NAME] 任务 [$name] 同步完成 ✅ (拉取)"
    fi
    
}

batch_run() {
    read -p "批量任务编号(多个逗号或 all): " nums
    if [[ "$nums" == "all" ]]; then
        nums=$(seq 1 $(grep -cve '^\s*$' "$CONFIG_FILE"))
    fi
    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        run_task "$1" "$n"
    done
    IFS=$OLDIFS
}

#################################
# 定时任务
#################################
schedule_task() {
    echo -e "${GREEN}定时任务模板:${RESET}"
    echo -e "${GREEN}1) 每天0点${RESET}"
    echo -e "${GREEN}2) 每周一0点${RESET}"
    echo -e "${GREEN}3) 每月1号0点${RESET}"
    echo -e "${GREEN}4) 自定义cron${RESET}"
    read -p "选择模板: " tmpl
    case $tmpl in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "cron表达式: " cron ;;
        *) echo -e "${RED}无效选择${RESET}"; return ;;
    esac

    read -p "任务编号(多个逗号或 all): " nums
    if [[ "$nums" == "all" ]]; then
        nums=$(seq 1 $(grep -cve '^\s*$' "$CONFIG_FILE"))
    fi
    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        job="$cron /bin/bash $SCRIPT_PATH auto push $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"
        crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
        echo -e "${GREEN}✅ 任务编号 $n 已添加定时任务${RESET}"
    done
    IFS=$OLDIFS
}

delete_schedule() {
    read -p "删除任务编号(多个逗号或 all): " nums
    if [[ "$nums" == "all" ]]; then
        crontab -l 2>/dev/null | grep -v "# rsync_" | crontab -
        echo -e "${YELLOW}✅ 已删除全部定时任务${RESET}"
        return
    fi
    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        crontab -l 2>/dev/null | grep -v "# rsync_$n" | crontab -
        echo -e "${YELLOW}✅ 已删除任务编号 $n 的定时任务${RESET}"
    done
    IFS=$OLDIFS
}

#################################
# 更新 & 卸载
#################################
update_self() {
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}已更新脚本${RESET}"
}

uninstall_self() {
    crontab -l 2>/dev/null | grep -v "rsync_" | crontab - || true
    rm -rf "$BASE_DIR"
    echo -e "${RED}已卸载脚本${RESET}"
    exit
}

#################################
# Cron 自动运行
#################################
if [[ "$1" == "auto" ]]; then
    run_task "$2" "$3"
    exit
fi

#################################
# 首次运行安装快捷命令
#################################
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}首次运行，下载脚本到本地...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/s"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/S"
    echo -e "${GREEN}✅ 快捷键已添加：s 或 S 可快速启动${RESET}"
fi

#################################
# 主菜单
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
    echo -e "${GREEN} 5) 批量推送同步${RESET}"
    echo -e "${GREEN} 6) 批量拉取同步${RESET}"
    echo -e "${GREEN} 7) 添加定时任务${RESET}"
    echo -e "${GREEN} 8) 删除定时任务${RESET}"
    echo -e "${GREEN} 9) Telegram设置${RESET}"
    echo -e "${GREEN}10) 更新脚本${RESET}"
    echo -e "${GREEN}11) 卸载脚本${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择操作: ${RESET}) " c
    case $c in
        1) add_task ;;
        2) delete_task ;;
        3) run_task push ;;
        4) run_task pull ;;
        5) batch_run push ;;
        6) batch_run pull ;;
        7) schedule_task ;;
        8) delete_schedule ;;
        9) setup_tg ;;
        10) update_self ;;
        11) uninstall_self ;;
        0) exit ;;
    esac
    read -p "回车继续..."
done
