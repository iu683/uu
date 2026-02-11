#!/bin/bash
# ==================================================
# GitHub VPS 多目录备份恢复工具（终极版）
# 功能：
# ✅ 多目录备份
# ✅ 恢复
# ✅ /opt 目录规范
# ✅ Telegram 通知
# ✅ 自定义 cron
# ✅ GitHub SSH 自动配置 ⭐新增
# ==================================================

BASE_DIR="/opt/github-backup"
CONFIG_FILE="$BASE_DIR/.ghupload_config"
LOG_FILE="$BASE_DIR/github_upload.log"
TMP_BASE="$BASE_DIR/tmp"
DOWNLOAD_DIR="$BASE_DIR/restore"
SCRIPT_PATH="$BASE_DIR/gh_tool.sh"
BIN_LINK_DIR="/usr/local/bin"

mkdir -p "$BASE_DIR" "$TMP_BASE" "$DOWNLOAD_DIR"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

REPO_URL=""
BRANCH="main"
COMMIT_PREFIX="VPS-Backup"
UPLOAD_DIRS=()

TG_BOT_TOKEN=""
TG_CHAT_ID=""

# ==================================================
# Telegram
# ==================================================
send_tg(){
    [ -z "$TG_BOT_TOKEN" ] && return
    [ -z "$TG_CHAT_ID" ] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" -d text="$1" >/dev/null 2>&1
}

# ==================================================
# GitHub SSH 自动配置 ⭐新增
# ==================================================
setup_github_ssh(){

echo -e "${GREEN}=== GitHub SSH 自动配置 ===${RESET}"

mkdir -p ~/.ssh

if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
    echo -e "${GREEN}已生成 SSH Key${RESET}"
else
    echo -e "${YELLOW}SSH Key 已存在${RESET}"
fi

eval "$(ssh-agent -s)" >/dev/null
ssh-add ~/.ssh/id_rsa >/dev/null

ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

PUB=$(cat ~/.ssh/id_rsa.pub)

read -p "GitHub Personal Access Token(admin:public_key): " GH_TOKEN

TITLE="VPS_$(hostname)_$(date +%s)"

RESP=$(curl -s -o /dev/null -w "%{http_code}" \
-H "Authorization: token $GH_TOKEN" \
-d "{\"title\":\"$TITLE\",\"key\":\"$PUB\"}" \
https://api.github.com/user/keys)

if [ "$RESP" = "201" ]; then
    echo -e "${GREEN}✅ Key 已添加到 GitHub${RESET}"
elif [ "$RESP" = "422" ]; then
    echo -e "${YELLOW}Key 已存在，跳过${RESET}"
else
    echo -e "${RED}❌ 添加失败，请检查 Token${RESET}"
fi

pause
}

# ==================================================
# 工具函数
# ==================================================
slug_path(){ echo "$1" | sed 's|^/||; s|/|_|g'; }
pause(){ read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"; }

save_config(){
cat > "$CONFIG_FILE" <<EOF
REPO_URL="$REPO_URL"
BRANCH="$BRANCH"
UPLOAD_DIRS="${UPLOAD_DIRS[*]}"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

load_config(){ [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"; }

# ==================================================
# 初始化
# ==================================================
init_config(){

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

read -p "启用 TG 通知?(y/n): " t
if [[ "$t" == "y" ]]; then
    read -p "Bot Token: " TG_BOT_TOKEN
    read -p "Chat ID: " TG_CHAT_ID
fi

save_config
pause
}

# ==================================================
# 备份
# ==================================================
upload_files(){

load_config

TMP_DIR=$(mktemp -d -p "$TMP_BASE")

git clone -b "$BRANCH" "$REPO_URL" "$TMP_DIR/repo" >>"$LOG_FILE" 2>&1 || {
    send_tg "❌ clone失败"
    return
}

count=0

for dir in ${UPLOAD_DIRS[@]}; do
    [ -d "$dir" ] || continue
    name=$(slug_path "$dir")
    mkdir -p "$TMP_DIR/repo/$name"
    rsync -a "$dir/" "$TMP_DIR/repo/$name/"
    ((count++))
done

cd "$TMP_DIR/repo"
git add -A
git commit -m "$COMMIT_PREFIX $(date '+%F %T')" >/dev/null 2>&1 || true

if git push >>"$LOG_FILE" 2>&1; then
    send_tg "✅ 备份成功 目录:$count"
else
    send_tg "❌ push失败"
fi
}

# ==================================================
# 恢复
# ==================================================
restore_backup(){
load_config
TMP_DIR=$(mktemp -d -p "$TMP_BASE")
git clone -b "$BRANCH" "$REPO_URL" "$TMP_DIR/repo"
rsync -a "$TMP_DIR/repo/" "$DOWNLOAD_DIR/"
pause
}

# ==================================================
# cron
# ==================================================
set_cron(){
read -p "cron 表达式: " expr
CMD="bash $SCRIPT_PATH upload >> $LOG_FILE 2>&1 #GHBACKUP"
(crontab -l 2>/dev/null | grep -v GHBACKUP; echo "$expr $CMD") | crontab -
pause
}

remove_cron(){ crontab -l 2>/dev/null | grep -v GHBACKUP | crontab -; pause; }

# ==================================================
# 菜单
# ==================================================
menu(){
clear
echo -e "${GREEN}============================${RESET}"
echo -e "${GREEN} GitHub VPS 备份恢复工具 ${RESET}"
echo -e "${GREEN}============================${RESET}"
echo -e "${GREEN}1) 初始化配置${RESET}"
echo -e "${GREEN}2) 立即备份${RESET}"
echo -e "${GREEN}3) 恢复备份${RESET}"
echo -e "${GREEN}4) 设置定时任务${RESET}"
echo -e "${GREEN}5) 删除定时任务${RESET}"
echo -e "${GREEN}6) 配置 GitHub SSH${RESET}"
echo -e "${GREEN}0) 退出${RESET}"

read -p "$(echo -e ${GREEN}请选择: ${RESET})" o

case $o in
1) init_config;;
2) upload_files;;
3) restore_backup;;
4) set_cron;;
5) remove_cron;;
6) setup_github_ssh;;
0) exit;;
esac

menu
}

ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/s"
ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/S"

case "$1" in
upload) upload_files; exit;;
esac

menu
