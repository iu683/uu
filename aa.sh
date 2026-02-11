#!/bin/bash

# ==============================
# ⭐ GitHub 多目录备份工具（/opt 生产版 + TG + cron）
# ==============================

BASE_DIR="/opt/github-tool"
CONFIG_FILE="$BASE_DIR/.ghupload_config"
LOG_FILE="$BASE_DIR/github_upload.log"
TMP_BASE="$BASE_DIR/upload_tmp"
SCRIPT_PATH="$BASE_DIR/gh_tool.sh"
BIN_LINK_DIR="/usr/local/bin"

mkdir -p "$BASE_DIR" "$TMP_BASE"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

REPO_URL=""
BRANCH="main"
COMMIT_PREFIX="VPS-Backup"

UPLOAD_DIRS=()
DOWNLOAD_DIR="$BASE_DIR/restore"

TG_BOT_TOKEN=""
TG_CHAT_ID=""


# ==============================
# TG 通知
# ==============================
send_tg(){
    [ -z "$TG_BOT_TOKEN" ] && return
    [ -z "$TG_CHAT_ID" ] && return

    curl -s -X POST \
    "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$1" >/dev/null 2>&1
}


# ==============================
# 工具函数
# ==============================
slug_path(){
    echo "$1" | sed 's|^/||; s|/|_|g'
}

pause(){
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
}

save_config(){
cat > "$CONFIG_FILE" <<EOF
REPO_URL="$REPO_URL"
BRANCH="$BRANCH"
COMMIT_PREFIX="$COMMIT_PREFIX"
TMP_BASE="$TMP_BASE"
DOWNLOAD_DIR="$DOWNLOAD_DIR"
UPLOAD_DIRS="${UPLOAD_DIRS[*]}"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

load_config(){
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}


# ==============================
# 初始化
# ==============================
init_config(){

echo -e "${GREEN}=== 初始化配置 ===${RESET}"

read -p "GitHub SSH 仓库地址: " REPO_URL
read -p "分支(默认 main): " BRANCH
BRANCH=${BRANCH:-main}

echo "输入需要备份的目录(空行结束)"
UPLOAD_DIRS=()
while true; do
    read -p "目录: " d
    [ -z "$d" ] && break
    UPLOAD_DIRS+=("$d")
done

read -p "是否启用 Telegram 通知(y/n): " tg
if [[ "$tg" == "y" ]]; then
    read -p "Bot Token: " TG_BOT_TOKEN
    read -p "Chat ID: " TG_CHAT_ID
fi

save_config
echo -e "${GREEN}✅ 初始化完成${RESET}"
pause
}


# ==============================
# 上传
# ==============================
upload_files(){

load_config

TMP_DIR=$(mktemp -d -p "$TMP_BASE")

git clone -b "$BRANCH" "$REPO_URL" "$TMP_DIR/repo" >>"$LOG_FILE" 2>&1 || {
    echo -e "${RED}❌ clone失败${RESET}"
    send_tg "❌ VPS备份失败：clone失败"
    return
}

count=0

for dir in ${UPLOAD_DIRS[@]}; do
    if [ -d "$dir" ]; then
        name=$(slug_path "$dir")
        mkdir -p "$TMP_DIR/repo/$name"
        rsync -a "$dir/" "$TMP_DIR/repo/$name/"
        ((count++))
    fi
done

cd "$TMP_DIR/repo" || return

git add -A
git commit -m "$COMMIT_PREFIX $(date '+%F %T')" >/dev/null 2>&1 || true

if git push >>"$LOG_FILE" 2>&1; then
    echo -e "${GREEN}✅ 备份完成${RESET}"
    send_tg "✅ VPS备份成功
时间: $(date '+%F %T')
目录数: $count"
else
    send_tg "❌ VPS备份失败：push错误"
fi

}


# ==============================
# cron（自定义）
# ==============================
set_cron(){

read -p "输入 cron 表达式: " cron_expr

CRON_CMD="bash $SCRIPT_PATH upload >> $LOG_FILE 2>&1 #GHUPLOAD"

(crontab -l 2>/dev/null | grep -v GHUPLOAD; echo "$cron_expr $CRON_CMD") | crontab -

echo -e "${GREEN}✅ 定时任务已设置${RESET}"
pause
}

remove_cron(){
crontab -l 2>/dev/null | grep -v GHUPLOAD | crontab -
echo -e "${GREEN}✅ 已删除${RESET}"
pause
}


# ==============================
# 菜单（绿色）
# ==============================
menu(){

clear
echo -e "${GREEN}=================================${RESET}"
echo -e "${GREEN} GitHub VPS 自动备份工具 ${RESET}"
echo -e "${GREEN}=================================${RESET}"
echo -e "${GREEN}1) 初始化配置${RESET}"
echo -e "${GREEN}2) 立即备份${RESET}"
echo -e "${GREEN}3) 设置定时任务${RESET}"
echo -e "${GREEN}4) 删除定时任务${RESET}"
echo -e "${GREEN}0) 退出${RESET}"
read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" opt

case $opt in
1) init_config;;
2) upload_files;;
3) set_cron;;
4) remove_cron;;
0) exit;;
esac

menu
}


case "$1" in
upload) upload_files; exit;;
esac

menu
