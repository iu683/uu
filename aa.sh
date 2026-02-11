#!/bin/bash
# =========================================================
# VPS <-> GitHub 目录备份恢复工具 Pro（最终版）
# =========================================================

# ==============================
# 基础路径
# ==============================
BASE_DIR="/opt/github-backup"
CONFIG_FILE="$BASE_DIR/.config"
LOG_FILE="$BASE_DIR/run.log"
TMP_BASE="$BASE_DIR/tmp"
SCRIPT_PATH="$BASE_DIR/gh_tool.sh"
BIN_DIR="/usr/local/bin"

mkdir -p "$BASE_DIR" "$TMP_BASE"

# ==============================
# 颜色
# ==============================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ==============================
# 全局变量
# ==============================
REPO_URL=""
BRANCH="main"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
BACKUP_LIST=()

# ==============================
# Telegram
# ==============================
send_tg(){
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d text="$1" >/dev/null
}

# ==============================
# 配置保存/加载
# ==============================
save_config(){
cat > "$CONFIG_FILE" <<EOF
REPO_URL="$REPO_URL"
BRANCH="$BRANCH"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
BACKUP_LIST="${BACKUP_LIST[*]}"
EOF
}

load_config(){
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    BACKUP_LIST=($BACKUP_LIST)
}

# ==============================
# SSH Key 自动生成 + 自动上传 GitHub
# ==============================
setup_ssh(){
    mkdir -p ~/.ssh
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        echo -e "${GREEN}✅ SSH Key 已生成${RESET}"
    fi

    eval "$(ssh-agent -s)" >/dev/null
    ssh-add ~/.ssh/id_rsa >/dev/null 2>&1
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

    PUB_KEY_CONTENT=$(cat "$HOME/.ssh/id_rsa.pub")

    read -p "请输入 GitHub 用户名: " GH_USER
    read -s -p "请输入 GitHub PAT (admin:public_key 权限): " GH_TOKEN
    echo ""

    TITLE="VPS_$(date '+%Y%m%d%H%M%S')"

    RESP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: token $GH_TOKEN" \
        -d "{\"title\":\"$TITLE\",\"key\":\"$PUB_KEY_CONTENT\"}" \
        https://api.github.com/user/keys)

    if [ "$RESP" -eq 201 ]; then
        echo -e "${GREEN}✅ SSH Key 已成功上传 GitHub${RESET}"
    elif [ "$RESP" -eq 422 ]; then
        echo -e "${YELLOW}⚠️ 公钥已存在${RESET}"
    else
        echo -e "${RED}❌ SSH Key 上传失败${RESET}"
    fi
}

# ==============================
# 初始化配置
# ==============================
init_config(){
    setup_ssh

    read -p "GitHub 仓库 SSH 地址: " REPO_URL
    read -p "分支(默认 main): " BRANCH
    BRANCH=${BRANCH:-main}

    read -p "配置 Telegram 通知？(y/n): " t
    if [[ "$t" == "y" ]]; then
        read -p "TG BOT TOKEN: " TG_BOT_TOKEN
        read -p "TG CHAT ID: " TG_CHAT_ID
    fi

    # 配置 Git 用户名和邮箱
    git config --global user.name "$GH_USER"
    git config --global user.email "$GH_USER@example.com"

    save_config
    echo -e "${GREEN}✅ 初始化完成${RESET}"
    read
}

# ==============================
# 添加备份目录
# ==============================
add_dirs(){
    load_config
    while true; do
        read -p "输入备份目录(回车结束): " d
        [[ -z "$d" ]] && break
        if [ -d "$d" ]; then
            BACKUP_LIST+=("$d")
        else
            echo -e "${RED}目录不存在${RESET}"
        fi
    done
    save_config
}

# ==============================
# 查看目录
# ==============================
show_dirs(){
    load_config
    echo -e "${GREEN}当前备份目录:${RESET}"
    for d in "${BACKUP_LIST[@]}"; do
        echo "$d"
    done
    read
}

# ==============================
# 备份核心
# ==============================
backup_now(){
    load_config

    TMP=$(mktemp -d -p "$TMP_BASE")
    echo -e "${GREEN}临时目录: $TMP${RESET}"

    git clone -b "$BRANCH" "$REPO_URL" "$TMP/repo" >>"$LOG_FILE" 2>&1 || {
        echo -e "${RED}❌ Git clone 失败${RESET}"
        send_tg "❌ Git clone 失败 $(hostname)"
        return
    }

    > "$TMP/repo/.backup_map"

    for dir in "${BACKUP_LIST[@]}"; do
        [ ! -d "$dir" ] && echo -e "${YELLOW}⚠️ 目录不存在，跳过: $dir${RESET}" && continue

        safe=$(echo -n "$dir" | md5sum | awk '{print $1}')
        mkdir -p "$TMP/repo/$safe"
        echo "$dir" >> "$TMP/repo/.backup_map"

        # 空目录也添加 .gitkeep
        [ -z "$(ls -A "$dir")" ] && touch "$dir/.gitkeep"

        echo -e "${GREEN}备份 $dir → $safe${RESET}"
        rsync -a --delete "$dir/" "$TMP/repo/$safe/"

        # 强制添加标记保证 commit
        echo $(date '+%F %T') > "$TMP/repo/$safe/.backup_marker"
    done

    cd "$TMP/repo" || return

    git add -A
    git commit -m "Backup $(date '+%F %T')" >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ 没有文件变化，但标记已强制 commit${RESET}"

    if git push origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
        echo -e "${GREEN}✅ 备份成功${RESET}"
        send_tg "✅ VPS 备份成功 $(hostname)"
    else
        echo -e "${RED}❌ Git push 失败${RESET}"
        send_tg "❌ VPS 备份失败 $(hostname)"
    fi
}

# ==============================
# 恢复
# ==============================
restore_now(){
    load_config

    TMP=$(mktemp -d -p "$TMP_BASE")
    git clone -b "$BRANCH" "$REPO_URL" "$TMP/repo" || return

    while read -r dir; do
        safe=$(echo -n "$dir" | md5sum | awk '{print $1}')
        mkdir -p "$dir"
        rsync -a --delete "$TMP/repo/$safe/" "$dir/"
    done < "$TMP/repo/.backup_map"

    echo -e "${GREEN}✅ 恢复完成${RESET}"
    send_tg "♻️ VPS恢复完成 $(hostname)"
}

# ==============================
# Cron
# ==============================
set_cron(){
    read -p "cron 表达式: " c
    CMD="bash $SCRIPT_PATH backup >> $LOG_FILE 2>&1 #GHBACK"
    (crontab -l 2>/dev/null | grep -v GHBACK; echo "$c $CMD") | crontab -
}

remove_cron(){
    crontab -l 2>/dev/null | grep -v GHBACK | crontab -
}

# ==============================
# 菜单
# ==============================
menu(){
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    VPS <-> GitHub 工具       ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) 初始化配置${RESET}"
    echo -e "${GREEN} 2) 添加备份目录${RESET}"
    echo -e "${GREEN} 3) 查看备份目录${RESET}"
    echo -e "${GREEN} 4) 立即备份${RESET}"
    echo -e "${GREEN} 5) 恢复到原路径${RESET}"
    echo -e "${GREEN} 6) 设置定时任务${RESET}"
    echo -e "${GREEN} 7) 删除定时任务${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read opt
    case $opt in
        1) init_config ;;
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

# ==============================
# Cron 模式
# ==============================
case "$1" in
    backup) backup_now; exit ;;
    restore) restore_now; exit ;;
esac

menu
