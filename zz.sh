#!/bin/bash
# =========================================================
# VPS <-> GitHub 目录备份恢复工具 Pro（最终版）
# 支持压缩备份 + 自定义备份目录 + 自动过期清理 + GitHub 上传
# 修复 Git clone 临时目录问题，恢复到原目录
# =========================================================

BASE_DIR="/opt/github-backup"
CONFIG_FILE="$BASE_DIR/.config"
LOG_FILE="$BASE_DIR/run.log"
TMP_BASE="$BASE_DIR/tmp"
SCRIPT_PATH="$BASE_DIR/gh_tool.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/zz.sh"

mkdir -p "$BASE_DIR" "$TMP_BASE"
chmod 700 "$BASE_DIR" "$TMP_BASE"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# =====================
# 默认配置
# =====================
REPO_URL=""
BRANCH="main"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
BACKUP_LIST=()
SERVER_NAME=""
ARCHIVE_FMT="tar.gz"
KEEP_DAYS=7
BACKUP_DIR="$BASE_DIR/backups"
mkdir -p "$BACKUP_DIR"

# =====================
# 自动下载主脚本
# =====================
download_script(){
    if [ ! -f "$SCRIPT_PATH" ]; then
        curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH" || {
            echo -e "${RED}❌ 下载失败${RESET}"
            exit 1
        }
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}✅ 脚本已下载: $SCRIPT_PATH${RESET}"
    fi
}
download_script

# =====================
# Telegram 消息
# =====================
send_tg(){
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    MSG="$1"
    [[ -n "$SERVER_NAME" ]] && MSG="[$SERVER_NAME] $MSG"
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d text="$MSG" >/dev/null
}

# =====================
# 配置保存/加载
# =====================
save_config(){
cat > "$CONFIG_FILE" <<EOF
REPO_URL="$REPO_URL"
BRANCH="$BRANCH"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
BACKUP_LIST="${BACKUP_LIST[*]}"
SERVER_NAME="$SERVER_NAME"
ARCHIVE_FMT="$ARCHIVE_FMT"
KEEP_DAYS="$KEEP_DAYS"
BACKUP_DIR="$BACKUP_DIR"
EOF
}

load_config(){
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    BACKUP_LIST=($BACKUP_LIST)
}

# =====================
# SSH Key 自动生成 + 上传 GitHub
# =====================
setup_ssh(){
    mkdir -p ~/.ssh
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        echo -e "${GREEN}✅ SSH Key 已生成${RESET}"
    fi
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add ~/.ssh/id_rsa >/dev/null 2>&1
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

    PUB_KEY_CONTENT=$(cat ~/.ssh/id_rsa.pub)
    read -p "请输入 GitHub 用户名: " GH_USER
    read -s -p "请输入 GitHub PAT (admin:public_key 权限): " GH_TOKEN
    echo ""

    TITLE="VPS_$(date '+%Y%m%d%H%M%S')"
    RESP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "Authorization: token $GH_TOKEN" \
        -d "{\"title\":\"$TITLE\",\"key\":\"$PUB_KEY_CONTENT\"}" \
        https://api.github.com/user/keys)

    if [ "$RESP" -eq 201 ]; then
        echo -e "${GREEN}✅ SSH Key 已上传 GitHub${RESET}"
    elif [ "$RESP" -eq 422 ]; then
        echo -e "${YELLOW}⚠️ 公钥已存在${RESET}"
    else
        echo -e "${RED}❌ SSH Key 上传失败${RESET}"
    fi

    git config --global user.name "$GH_USER"
    git config --global user.email "$GH_USER@example.com"
}

# =====================
# 初始化配置
# =====================
init_config(){
    setup_ssh
    read -p "请输入 GitHub 仓库地址 (SSH, 例如 git@github.com:USER/REPO.git): " REPO_URL
    read -p "分支(默认 main): " BRANCH
    BRANCH=${BRANCH:-main}
    read -p "服务器名称 (Telegram 通知显示): " SERVER_NAME
    read -p "配置 Telegram 通知？(y/n): " t
    if [[ "$t" == "y" ]]; then
        read -p "TG BOT TOKEN: " TG_BOT_TOKEN
        read -p "TG CHAT ID: " TG_CHAT_ID
    fi
    save_config
    echo -e "${GREEN}✅ 初始化完成${RESET}"
    read -p "按回车返回菜单..."
}

# =====================
# 设置备份目录
# =====================
set_backup_dir(){
    load_config
    echo -e "${GREEN}当前备份目录: $BACKUP_DIR${RESET}"
    read -p "请输入新的备份目录（留空保持当前）: " dir
    if [ -n "$dir" ]; then
        BACKUP_DIR="$dir"
        mkdir -p "$BACKUP_DIR"
        save_config
        echo -e "${GREEN}✅ 已更新备份目录: $BACKUP_DIR${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# =====================
# 设置备份参数
# =====================
set_backup_params(){
    load_config
    echo -e "${GREEN}当前压缩格式: $ARCHIVE_FMT${RESET}"
    read -p "选择备份文件格式 (1: tar.gz, 2: zip，留空保持当前): " f
    case $f in
        1) ARCHIVE_FMT="tar.gz";;
        2) ARCHIVE_FMT="zip";;
        *) echo -e "${YELLOW}保持当前格式${RESET}";;
    esac

    echo -e "${GREEN}当前备份文件保留天数: $KEEP_DAYS${RESET}"
    read -p "设置备份文件保留天数（留空保持当前）: " kd
    if [ -n "$kd" ]; then
        KEEP_DAYS="$kd"
    fi

    save_config
    echo -e "${GREEN}✅ 备份参数已更新${RESET}"
    read -p "按回车返回菜单..."
}

# =====================
# 添加备份目录
# =====================
add_dirs(){
    load_config
    echo -e "${GREEN}输入要备份的目录，可以一次输入多个，用空格分隔:${RESET}"
    read -p "目录: " dirs
    for d in $dirs; do
        if [ -d "$d" ]; then
            BACKUP_LIST+=("$d")
            echo -e "${GREEN}✅ 添加成功: $d${RESET}"
        else
            echo -e "${RED}⚠️ 目录不存在，跳过: $d${RESET}"
        fi
    done
    save_config
    read -p "按回车返回菜单..."
}

# =====================
# 查看备份目录
# =====================
show_dirs(){
    load_config
    echo -e "${GREEN}当前备份目录:${RESET}"
    for d in "${BACKUP_LIST[@]}"; do
        echo -e "${GREEN}$d${RESET}"
    done
    read -p "按回车返回菜单..."
}

# =====================
# 执行压缩备份（保留原路径）并清理 GitHub 历史备份
# =====================
backup_now(){
    load_config
    mkdir -p "$BASE_DIR" "$TMP_BASE" "$BACKUP_DIR"
    cd "$BASE_DIR" || exit 1
    TMP=$(mktemp -d -p "$TMP_BASE")
    echo -e "${GREEN}临时目录: $TMP${RESET}"

    # ---------------------
    # 生成备份文件
    # ---------------------
    for dir in "${BACKUP_LIST[@]}"; do
        [ ! -d "$dir" ] && echo -e "${YELLOW}⚠️ 目录不存在，跳过: $dir${RESET}" && continue
        safe=$(echo -n "$dir" | md5sum | awk '{print $1}')
        basename=$(basename "$dir")
        backup_name="${BACKUP_DIR}/${basename}_${safe}_$(date '+%Y%m%d%H%M%S')"

        echo -e "${GREEN}备份 $dir → $backup_name.${ARCHIVE_FMT}${RESET}"
        if [ "$ARCHIVE_FMT" == "tar.gz" ]; then
            tar -czf "$backup_name.tar.gz" -C "/" "$(echo "$dir" | sed 's|^/||')"
        else
            cd / || continue
            zip -r "$backup_name.zip" "$(echo "$dir" | sed 's|^/||')" >/dev/null
        fi
    done

    # ---------------------
    # 删除本地过期备份
    # ---------------------
    find "$BACKUP_DIR" -type f -mtime +$KEEP_DAYS -exec rm -f {} \;
    echo -e "${YELLOW}🗑️ 已删除 $KEEP_DAYS 天前的本地备份${RESET}"

    # ---------------------
    # Git 上传并清理 GitHub 历史备份
    # ---------------------
    TMP_REPO="$TMP/repo"
    git clone -b "$BRANCH" "$REPO_URL" "$TMP_REPO" >>"$LOG_FILE" 2>&1 || {
        echo -e "${RED}❌ Git clone 失败${RESET}"
        send_tg "❌ Git clone 失败"
        rm -rf "$TMP"
        return
    }

    cd "$TMP_REPO" || return

    # 删除 Git 仓库中超过 KEEP_DAYS 天的备份文件
    find . -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.zip" \) -mtime +$KEEP_DAYS -exec git rm -f {} \;

    # 复制最新本地备份到仓库
    cp "$BACKUP_DIR"/* . 2>/dev/null || true

    git add -A
    git commit -m "Backup $(date '+%F %T')" >/dev/null 2>&1 || echo -e "${YELLOW}⚠️ 没有文件变化${RESET}"

    if git push origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
        echo -e "${GREEN}✅ 备份成功并清理 GitHub 历史备份${RESET}"
        send_tg "✅ VPS<->GitHub 备份成功"
    else
        echo -e "${RED}❌ Git push 失败${RESET}"
        send_tg "❌ VPS<->GitHub 备份失败"
    fi

    rm -rf "$TMP"
}

# =====================
# 恢复备份到原目录（只恢复最新备份）
# =====================
restore_now(){
    load_config
    mkdir -p "$BASE_DIR" "$TMP_BASE"
    cd "$BASE_DIR" || exit 1
    TMP=$(mktemp -d -p "$TMP_BASE")
    echo -e "${GREEN}临时目录: $TMP${RESET}"

    TMP_REPO="$TMP/repo"
    git clone -b "$BRANCH" "$REPO_URL" "$TMP_REPO" >>"$LOG_FILE" 2>&1 || {
        echo -e "${RED}❌ Git clone 失败${RESET}"
        send_tg "❌ Git clone 恢复失败"
        rm -rf "$TMP"
        return
    }

    for dir in "${BACKUP_LIST[@]}"; do
        safe=$(echo -n "$dir" | md5sum | awk '{print $1}')
        basename=$(basename "$dir")
        # 找到最新备份文件（按时间戳排序）
        latest_file=$(ls -1 "$TMP_REPO/${basename}_${safe}_"* 2>/dev/null | sort -r | head -n1)
        if [ -z "$latest_file" ]; then
            echo -e "${YELLOW}⚠️ 找不到备份: $dir${RESET}"
            continue
        fi

        echo -e "${GREEN}恢复最新备份: $latest_file → $dir${RESET}"
        mkdir -p "$dir"
        if [[ "$latest_file" == *.tar.gz ]]; then
            tar -xzf "$latest_file" -C /
        elif [[ "$latest_file" == *.zip ]]; then
            unzip -o "$latest_file" -d /
        fi
    done

    rm -rf "$TMP"
    echo -e "${GREEN}✅ 恢复完成${RESET}"
    send_tg "♻️ VPS<->GitHub 恢复完成"
}

# =====================
# 设置 Telegram 参数
# =====================
set_telegram(){
    load_config
    echo -e "${GREEN}当前 Telegram 参数:${RESET}"
    echo -e "${GREEN}服务器名称: $SERVER_NAME${RESET}"
    echo -e "${GREEN}TG BOT TOKEN: $TG_BOT_TOKEN${RESET}"
    echo -e "${GREEN}TG CHAT ID: $TG_CHAT_ID${RESET}"

    read -p "输入服务器名称（留空保持当前）: " name
    [ -n "$name" ] && SERVER_NAME="$name"

    read -p "输入 TG BOT TOKEN（留空保持当前）: " token
    [ -n "$token" ] && TG_BOT_TOKEN="$token"

    read -p "输入 TG CHAT ID（留空保持当前）: " chat
    [ -n "$chat" ] && TG_CHAT_ID="$chat"

    save_config
    echo -e "${GREEN}✅ Telegram 参数已更新${RESET}"
    read -p "按回车返回菜单..."
}
# =====================
# 定时任务
# =====================
set_cron(){
    echo -e "${GREEN}选择定时备份时间:${RESET}"
    echo -e "${GREEN}1) 每5分钟${RESET}"
    echo -e "${GREEN}2) 每10分钟${RESET}"
    echo -e "${GREEN}3) 每30分钟${RESET}"
    echo -e "${GREEN}4) 每小时${RESET}"
    echo -e "${GREEN}5) 每天凌晨3点${RESET}"
    echo -e "${GREEN}6) 每周一凌晨0点${RESET}"
    echo -e "${GREEN}7) 自定义${RESET}"
    read -p "请输入选项 [1-7]: " choice

    case $choice in
        1) cron_expr="*/5 * * * *" ;;
        2) cron_expr="*/10 * * * *" ;;
        3) cron_expr="*/30 * * * *" ;;
        4) cron_expr="0 * * * *" ;;
        5) cron_expr="0 3 * * *" ;;
        6) cron_expr="0 0 * * 1" ;;
        7) read -p "请输入自定义 cron 表达式: " cron_expr ;;
        *) echo "无效选项"; read -p "按回车返回菜单..."; return ;;
    esac

    CMD="export HOME=/root; export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; bash $SCRIPT_PATH backup >> $LOG_FILE 2>&1 #GHBACK"
    (crontab -l 2>/dev/null | grep -v GHBACK; echo "$cron_expr $CMD") | crontab -
    echo -e "${GREEN}✅ 定时任务已设置: $cron_expr${RESET}"
}

remove_cron(){
    crontab -l 2>/dev/null | grep -v GHBACK | crontab -
    echo -e "${GREEN}✅ 定时任务已删除${RESET}"
}

# =====================
# 卸载脚本
# =====================
uninstall_script(){
    read -p "确认卸载脚本及清理所有文件和定时任务吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        remove_cron
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}✅ 脚本及所有备份文件已删除${RESET}"
        exit 0
    fi
}

# =====================
# 修改 GitHub 仓库地址
# =====================
modify_repo_url(){
    load_config
    echo -e "${GREEN}当前 GitHub 仓库地址: $REPO_URL${RESET}"
    read -p "请输入新的 GitHub 仓库地址（留空保持当前）: " url
    if [ -n "$url" ]; then
        REPO_URL="$url"
        save_config
        echo -e "${GREEN}✅ 仓库地址已更新: $REPO_URL${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# =====================
# 管理备份目录（添加/删除/查看）
# =====================
manage_backup_dirs(){
    load_config
    while true; do
        echo -e "${GREEN}当前备份目录列表:${RESET}"
        for i in "${!BACKUP_LIST[@]}"; do
            echo "$i) ${BACKUP_LIST[$i]}"
        done
        echo -e "${GREEN}1) 添加目录${RESET}"
        echo -e "${GREEN}2) 删除目录${RESET}"
        echo -e "${GREEN}0) 返回主菜单${RESET}"
        read -p "选择操作: " choice
        case "$choice" in
            1)
                read -p "请输入要添加的目录(可空格分隔): " dirs
                for d in $dirs; do
                    if [ -d "$d" ]; then
                        BACKUP_LIST+=("$d")
                        echo -e "${GREEN}✅ 添加成功: $d${RESET}"
                    else
                        echo -e "${RED}⚠️ 目录不存在: $d${RESET}"
                    fi
                done
                save_config
                ;;
            2)
                read -p "请输入要删除的目录编号(多个用空格): " idxs
                for idx in $idxs; do
                    unset BACKUP_LIST[$idx]
                done
                BACKUP_LIST=("${BACKUP_LIST[@]}")  # 重建索引
                save_config
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}

# =====================
# 修改菜单
# =====================
menu(){
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    VPS<->GitHub 备份工具       ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1) 初始化配置${RESET}"
    echo -e "${GREEN} 2) 修改GitHub仓库地址${RESET}"
    echo -e "${GREEN} 3) 管理备份目录（添加/删除/查看）${RESET}"
    echo -e "${GREEN} 4) 修改备份存放目录${RESET}"
    echo -e "${GREEN} 5) 备份参数设置压缩格式/保留天数）${RESET}"
    echo -e "${GREEN} 6) 修改Telegram参数${RESET}"
    echo -e "${GREEN} 7) 立即备份${RESET}"
    echo -e "${GREEN} 8) 恢复备份${RESET}"
    echo -e "${GREEN} 9) 设置定时任务${RESET}"
    echo -e "${GREEN}10) 删除定时任务${RESET}"
    echo -e "${GREEN}11) 卸载脚本${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -ne "${GREEN} 请输入选项: ${RESET}"
    read opt
    case $opt in
        1) init_config ;;
        2) modify_repo_url ;;
        3) manage_backup_dirs ;;
        4) set_backup_dir ;;
        5) set_backup_params ;;
        6) set_telegram ;;
        7) backup_now ;;
        8) restore_now ;;
        9) set_cron ;;
        10) remove_cron ;;
        11) uninstall_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; read -p "按回车返回菜单..." ;;
    esac
    menu
}


# =====================
# cron 模式
# =====================
case "$1" in
    backup) backup_now; exit ;;
    restore) restore_now; exit ;;
esac

menu
