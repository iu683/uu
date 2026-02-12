#!/bin/bash
set -e

#################################
# 颜色
#################################
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

#################################
# 路径配置
#################################
BASE_DIR="/opt/rsync_task"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/qq.sh"
BIN_LINK_DIR="/usr/local/bin"  # 全局快捷命令目录
CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"

mkdir -p "$BASE_DIR" "$KEY_DIR" "$LOG_DIR" "$BIN_LINK_DIR"
touch "$CONFIG_FILE"

#################################
# 首次运行自动安装 & 快捷键
#################################
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}首次运行，下载脚本...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"

    # 创建快捷命令 s / S
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/s"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/S"

    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}✅ 快捷键已添加：s 或 S 可快速启动${RESET}"
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
KEY_FILE="$KEY_DIR/id_rsa_rsync"
PUB_FILE="$KEY_DIR/id_rsa_rsync.pub"

generate_ssh_key() {
    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}未检测到本地 SSH 密钥，正在生成...${RESET}"
        mkdir -p "$KEY_DIR"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
        echo -e "${GREEN}✅ 本地 SSH 密钥生成完成: $KEY_FILE${RESET}"
    else
        echo -e "${GREEN}✅ 已检测到本地 SSH 密钥: $KEY_FILE${RESET}"
    fi
}
generate_ssh_key

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
        secret="$KEY_FILE"
        auth="key"
    fi
    echo "$name|$local|$remote|$remote_path|$port|$auth|$secret" >> "$CONFIG_FILE"
}

modify_task() {
    list_tasks
    read -p "请输入要修改的任务编号: " n
    task=$(sed -n "${n}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && { echo "任务不存在"; return; }
    IFS='|' read -r name local remote remote_path port auth secret <<< "$task"

    read -p "任务名称[$name]: " newname; newname=${newname:-$name}
    read -p "本地目录[$local]: " newlocal; newlocal=${newlocal:-$local}
    read -p "远程目录[$remote_path]: " newremote_path; newremote_path=${newremote_path:-$remote_path}
    read -p "远程用户@IP[$remote]: " newremote; newremote=${newremote:-$remote}
    read -p "端口[$port]: " newport; newport=${newport:-$port}

    sed -i "${n}s|.*|$newname|$newlocal|$newremote|$newremote_path|$newport|$auth|$secret|" "$CONFIG_FILE"
    echo -e "${GREEN}✅ 任务已修改${RESET}"
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
    [[ -z "$num" ]] && read -p "编号: " num
    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && { echo "任务不存在"; return; }

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
    fi

    source "$TG_CONFIG" 2>/dev/null || true
    send_tg "[$VPS_NAME] 任务 [$name] 同步 $direction 完成"
}

#################################
# 批量操作
#################################
batch_run() {
    direction="$1"
    list_tasks
    read -p "请输入任务编号（多个空格分开，回车为全部）: " nums
    if [[ -z "$nums" ]]; then
        nums=$(awk 'END{for(i=1;i<=NR;i++) print i}' "$CONFIG_FILE")
    fi
    for n in $nums; do
        run_task "$direction" "$n"
    done
}

#################################
# 定时任务
#################################
schedule_task() {
    list_tasks
    read -p "请输入任务编号（多个空格分开）: " nums
    [[ -z "$nums" ]] && { echo "未选择任务"; return; }

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

    for n in $nums; do
        job="$cron /usr/bin/bash $SCRIPT_PATH auto $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"
        crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
        echo -e "${GREEN}✅ 任务编号 $n 已添加定时任务${RESET}"
    done
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
# 主菜单
#################################
while true; do
    clear
    echo -e "${GREEN}===== Rsync 同步管理器 =====${RESET}"
    list_tasks
    echo
    echo -e "${GREEN} 1) 添加同步任务${RESET}"
    echo -e "${GREEN} 2) 修改同步任务${RESET}"
    echo -e "${GREEN} 3) 删除同步任务${RESET}"
    echo -e "${GREEN} 4) 推送同步${RESET}"
    echo -e "${GREEN} 5) 拉取同步${RESET}"
    echo -e "${GREEN} 6) 批量推送同步${RESET}"
    echo -e "${GREEN} 7) 批量拉取同步${RESET}"
    echo -e "${GREEN} 8) 添加定时任务${RESET}"
    echo -e "${GREEN} 9) 删除定时任务${RESET}"
    echo -e "${GREEN}10) Telegram设置${RESET}"
    echo -e "${GREEN}11) 更新脚本${RESET}"
    echo -e "${GREEN}12) 卸载脚本${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN} 请选择操作: ${RESET}) " c

    case $c in
        1) add_task ;;
        2) modify_task ;;
        3) delete_task ;;
        4) run_task push ;;
        5) run_task pull ;;
        6) batch_run push ;;
        7) batch_run pull ;;
        8) schedule_task ;;
        9) delete_schedule ;;
        10) setup_tg ;;
        11) update_self ;;
        12) uninstall_self ;;
        0) exit ;;
    esac
    read -p "回车继续..."
done
