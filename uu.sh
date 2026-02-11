#!/bin/bash

# ==================================================
# GitHub VPS 备份恢复工具 Pro
# 功能：
# ✅ 自定义多个目录备份
# ✅ 自动恢复到原路径
# ✅ GitHub SSH
# ✅ Telegram 通知
# ✅ 绿色菜单
# ✅ 定时任务 cron
# ✅ 统一 /opt
# ==================================================

BASE_DIR="/opt/github-backup"
CONFIG="$BASE_DIR/.config"
TMP_BASE="$BASE_DIR/tmp"
LOG="$BASE_DIR/run.log"
SCRIPT_PATH="$BASE_DIR/gh_tool.sh"
BIN="/usr/local/bin"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

mkdir -p "$BASE_DIR" "$TMP_BASE"

REPO_URL=""
BRANCH="main"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
BACKUP_LIST=()

# =========================
send_tg(){
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d text="$1" >/dev/null
}

# =========================
save_cfg(){
cat > "$CONFIG" <<EOF
REPO_URL="$REPO_URL"
BRANCH="$BRANCH"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
BACKUP_LIST="${BACKUP_LIST[*]}"
EOF
}

load_cfg(){
    [ -f "$CONFIG" ] && source "$CONFIG"
}

# =========================
setup_ssh(){
    mkdir -p ~/.ssh

    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
    fi

    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

    echo -e "${GREEN}把下面公钥添加到 GitHub → SSH Keys:${RESET}"
    cat ~/.ssh/id_rsa.pub
    read -p "添加完成后回车继续..."
}

# =========================
init_repo(){
    setup_ssh

    read -p "仓库 SSH 地址: " REPO_URL
    read -p "分支(默认 main): " BRANCH
    BRANCH=${BRANCH:-main}

    read -p "配置 Telegram 通知？(y/n): " t
    if [[ "$t" == "y" ]]; then
        read -p "TG BOT TOKEN: " TG_BOT_TOKEN
        read -p "TG CHAT ID: " TG_CHAT_ID
    fi

    save_cfg
}

# =========================
add_dirs(){
    load_cfg
    while true; do
        read -p "输入备份目录(回车结束): " d
        [[ -z "$d" ]] && break

        if [ -d "$d" ]; then
            BACKUP_LIST+=("$d")
        else
            echo -e "${RED}目录不存在${RESET}"
        fi
    done
    save_cfg
}

show_dirs(){
    load_cfg
    echo -e "${GREEN}当前备份目录:${RESET}"
    for i in "${BACKUP_LIST[@]}"; do
        echo "$i"
    done
    read -p "回车继续..."
}

# =========================
backup_now(){
    load_cfg

    if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
        echo -e "${RED}未添加任何备份目录${RESET}"
        return
    fi

    TMP=$(mktemp -d -p "$TMP_BASE")

    git clone -b "$BRANCH" "$REPO_URL" "$TMP/repo" || return

    > "$TMP/repo/.backup_map"

    for dir in "${BACKUP_LIST[@]}"; do
        safe=$(echo "$dir" | sed 's#/#_#g')
        echo "$dir" >> "$TMP/repo/.backup_map"

        echo -e "${GREEN}备份 $dir${RESET}"
        rsync -a --delete "$dir/" "$TMP/repo/$safe/"
    done

    cd "$TMP/repo"

    git add -A
    git commit -m "Backup $(date '+%F %T')" >/dev/null 2>&1 || true

    if git push; then
        echo -e "${GREEN}✅ 备份成功${RESET}"
        send_tg "✅ VPS备份成功 $(hostname)"
    else
        echo -e "${RED}❌ 备份失败${RESET}"
    fi
}

# =========================
restore_now(){
    load_cfg

    TMP=$(mktemp -d -p "$TMP_BASE")

    git clone -b "$BRANCH" "$REPO_URL" "$TMP/repo" || return

    while read -r dir; do
        safe=$(echo "$dir" | sed 's#/#_#g')

        echo -e "${GREEN}恢复 $dir${RESET}"
        mkdir -p "$dir"
        rsync -a --delete "$TMP/repo/$safe/" "$dir/"
    done < "$TMP/repo/.backup_map"

    send_tg "♻️ VPS恢复完成 $(hostname)"
}

# =========================
set_cron(){
    read -p "输入 cron 表达式: " c
    cmd="bash $SCRIPT_PATH backup >> $LOG 2>&1 #GHBACK"
    (crontab -l 2>/dev/null | grep -v GHBACK; echo "$c $cmd") | crontab -
}

remove_cron(){
    crontab -l 2>/dev/null | grep -v GHBACK | crontab -
}

# =========================
menu(){
clear
echo -e "${GREEN}========= GitHub 备份恢复 =========${RESET}"
echo -e "${GREEN}1 初始化仓库/SSH${RESET}"
echo -e "${GREEN}2 添加备份目录${RESET}"
echo -e "${GREEN}3 查看备份目录${RESET}"
echo -e "${GREEN}4 立即备份${RESET}"
echo -e "${GREEN}5 恢复到原位置${RESET}"
echo -e "${GREEN}6 设置定时任务${RESET}"
echo -e "${GREEN}7 删除定时任务${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -p "选择: " n

case $n in
1) init_repo ;;
2) add_dirs ;;
3) show_dirs ;;
4) backup_now ;;
5) restore_now ;;
6) set_cron ;;
7) remove_cron ;;
0) exit ;;
esac

menu
}

ln -sf "$SCRIPT_PATH" "$BIN/s"

case "$1" in
backup) backup_now; exit ;;
restore) restore_now; exit ;;
esac

menu
