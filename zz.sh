#!/bin/bash
set -e

#################################
# 配置
#################################
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

BASE_DIR="/opt/rsync_task"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"
CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"
TEMP_ARCHIVE="/tmp/sync_temp.tar.gz"

mkdir -p "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

#################################
# 首次运行自动安装
#################################
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "${GREEN}首次运行，自动安装到本地...${RESET}"
    mkdir -p "$BASE_DIR"
    curl -sL "https://raw.githubusercontent.com/iu683/uu/main/zz.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    exec "$SCRIPT_PATH"
fi

#################################
# 安装依赖
#################################
install_dep() {
    for p in rsync ssh sshpass curl; do
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
generate_and_setup_ssh() {
    local remote="$1"
    local port="$2"

    KEY_FILE="$KEY_DIR/id_rsa_rsync"
    PUB_FILE="$KEY_DIR/id_rsa_rsync.pub"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}未检测到本地 SSH 密钥，正在生成...${RESET}"
        mkdir -p "$KEY_DIR"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
        echo -e "${GREEN}✅ 本地 SSH 密钥生成完成: $KEY_FILE${RESET}"
    else
        echo -e "${GREEN}✅ 已检测到本地 SSH 密钥: $KEY_FILE${RESET}"
    fi

    PUBKEY_CONTENT=$(cat "$PUB_FILE")

    # 移除远程 host key 冲突
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${remote#*@}" >/dev/null 2>&1

    echo -e "${YELLOW}⚠️ 第一次连接需要输入远程密码进行操作${RESET}"

    ssh -p "$port" "$remote" "bash -s" <<EOF
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak 2>/dev/null
awk '!seen[\$0]++' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
grep -Fxq "$PUBKEY_CONTENT" ~/.ssh/authorized_keys || echo "$PUBKEY_CONTENT" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown \$(whoami):\$(id -gn) ~/.ssh ~/.ssh/authorized_keys

# 安装依赖
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=\$ID
else
    OS=\$(uname -s)
fi

case \$OS in
    ubuntu|debian)
        apt update && apt install -y rsync openssh-client >/dev/null 2>&1
        ;;
    centos|rhel|rocky)
        yum install -y rsync openssh-clients >/dev/null 2>&1
        ;;
    alpine)
        apk add --no-cache rsync openssh-client >/dev/null 2>&1
        ;;
esac
EOF

    # 测试免密码登录
    ssh -i "$KEY_FILE" -p "$port" "$remote" "echo 2>&1" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✅ 公钥写入成功，可免密码登录 $remote${RESET}"
    else
        echo -e "${RED}❌ 公钥写入失败，请手动检查 SSH 配置${RESET}"
    fi
}

#################################
# 任务管理
#################################
list_tasks() {
    [[ ! -s "$CONFIG_FILE" ]] && { echo "暂无任务"; return; }
    awk -F'|' '{printf "%d) %s  %s -> %s [%s]\n",NR,$1,$2,$4,$6}' "$CONFIG_FILE"
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
# 同步压缩执行
#################################
run_task() {
    direction="$1"
    num="$2"

    [[ -z "$num" ]] && read -p "编号: " num
    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && exit 1

    IFS='|' read -r name local remote remote_path port auth secret <<< "$task"

    if [[ "$direction" == "push" ]]; then
        tar -czf "$TEMP_ARCHIVE" -C "$(dirname "$local")" "$(basename "$local")"
        dst="$remote:$remote_path/$(basename "$TEMP_ARCHIVE")"
        [[ "$auth" == "password" ]] && sshpass -p "$secret" rsync -avz -e "ssh -p $port" "$TEMP_ARCHIVE" "$dst" \
        || rsync -avz -e "ssh -i $secret -p $port" "$TEMP_ARCHIVE" "$dst"
        echo -e "${GREEN}✅ 已上传压缩包: $TEMP_ARCHIVE -> $dst${RESET}"
    else
        src="$remote:$remote_path/$(basename "$TEMP_ARCHIVE")"
        rm -rf "$local"
        [[ "$auth" == "password" ]] && sshpass -p "$secret" rsync -avz -e "ssh -p $port" "$src" "/tmp/" \
        || rsync -avz -e "ssh -i $secret -p $port" "$src" "/tmp/"
        mkdir -p "$local"
        tar -xzf "/tmp/$(basename "$TEMP_ARCHIVE")" -C "$(dirname "$local")"
        rm -f "/tmp/$(basename "$TEMP_ARCHIVE")"
        echo -e "${GREEN}✅ 已拉取并覆盖本地: $local${RESET}"
    fi

    source "$TG_CONFIG" 2>/dev/null || true
    send_tg "[$VPS_NAME] $name 同步 $direction 完成"
}

#################################
# 定时任务
#################################
schedule_task() {
    read -p "任务编号: " n
    echo -e "${GREEN}1) 每天0点${RESET}"
    echo -e "${GREEN}2) 每周一0点${RESET}"
    echo -e "${GREEN}3) 每月1号0点${RESET}"
    echo -e "${GREEN}4) 自定义cron表达式${RESET}"
    read -p "选择: " c
    case $c in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "请输入cron表达式: " cron ;;
        *) echo "取消"; return ;;
    esac
    job="$cron /usr/bin/bash $SCRIPT_PATH auto $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"
    crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
    echo -e "${GREEN}✅ 定时任务已添加${RESET}"
}

delete_schedule() {
    read -p "编号: " n
    crontab -l 2>/dev/null | grep -v "# rsync_$n" | crontab -
    echo -e "${GREEN}✅ 定时任务已删除${RESET}"
}

#################################
# 自动模式 (cron)
#################################
if [[ "$1" == "auto" ]]; then
    run_task push "$2"
    exit
fi

#################################
# 更新 & 卸载
#################################
update_self() {
    curl -sL "https://raw.githubusercontent.com/iu683/uu/main/aa.sh" -o "$SCRIPT_PATH"
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
