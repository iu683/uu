#!/bin/bash

#################################
# 颜色
#################################
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

#################################
# 首次运行安装（下载到 /opt）
#################################
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/oo.sh"
SCRIPT_PATH="/opt/vpsbackup/vpsbackup.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
    mkdir -p /opt/vpsbackup
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL" || {
        echo -e "${RED}❌ 下载失败${RESET}"
        exit 1
    }
    chmod +x "$SCRIPT_PATH"
    exec bash "$SCRIPT_PATH" "$@"
fi

#################################
# 安装目录 & 基础路径初始化
#################################
BASE_DIR="/opt/vpsbackup"
INSTALL_PATH="$BASE_DIR/vpsbackup.sh"
TG_CONF="$BASE_DIR/.tg.conf"
CONF_FILE="$BASE_DIR/.backup.conf"

#################################
# 默认配置
#################################
COMPRESS="tar"
KEEP_DAYS=7
SERVER_NAME=$(hostname)
BACKUP_LIST="/opt"
BACKUP_DIR="$BASE_DIR/backups" # 默认本地备份存放目录

#################################
# 读取/保存配置
#################################
load_conf(){
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -f "$TG_CONF" ] && source "$TG_CONF"
    mkdir -p "$BACKUP_DIR"
    IFS=' ' read -r -a BACKUP_ARRAY <<< "${BACKUP_LIST:-/opt}"
}

save_conf(){
cat > "$CONF_FILE" <<EOF
COMPRESS="$COMPRESS"
KEEP_DAYS=$KEEP_DAYS
SERVER_NAME="$SERVER_NAME"
BACKUP_LIST="$BACKUP_LIST"
BACKUP_DIR="$BACKUP_DIR"
EOF
}

#################################
# Telegram通知
#################################
tg_send(){
    [ -z "$BOT_TOKEN" ] && return

    curl -s -X POST \
    "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$1" >/dev/null 2>&1
}

#################################
# 日志
#################################
log(){
    echo "$(date '+%F %T') $1" >> "$BASE_DIR/backup.log"
}

#################################
# 清理旧备份
#################################
clean_old(){
    if [ "$COMPRESS" = "tar" ]; then
        find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null
    else
        find "$BACKUP_DIR" -name "*.zip" -mtime +$KEEP_DAYS -delete 2>/dev/null
    fi
}

#################################
# 备份核心（支持批量目录）
#################################
backup_dirs(){
    load_conf
    TS=$(date +%Y%m%d%H%M%S)

    dirs=("$@")
    [ ${#dirs[@]} -eq 0 ] && dirs=("${BACKUP_ARRAY[@]}")

    echo -e "${YELLOW}➔ 开始执行备份任务...${RESET}"
    for p in "${dirs[@]}"; do
        [ ! -d "$p" ] && { echo -e "${RED}❌ 目录不存在: $p${RESET}"; continue; }
        name=$(basename "$p")
        rel="${p#/}"

        if [ "$COMPRESS" = "tar" ]; then
            file="${name}_${TS}.tar.gz"
            tar -czf "$BACKUP_DIR/$file" -C / "$rel"
        else
            file="${name}_${TS}.zip"
            (cd / && zip -rq "$BACKUP_DIR/$file" "$rel")
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}🟢 备份成功: $file${RESET}"
            log "备份成功: $file"
            tg_send "🟢 备份成功
服务器: $SERVER_NAME
目录: $p
文件: $file"
        else
            echo -e "${RED}🔴 备份失败: $p${RESET}"
            log "备份失败: $file"
            tg_send "🔴 备份失败
服务器: $SERVER_NAME
目录: $p"
        fi
    done

    clean_old
}

#################################
# 创建备份
#################################
create_backup(){
    read -p "输入要备份的目录(多个用空格分隔，直接回车使用默认配置): " input
    if [ -z "$input" ]; then
        backup_dirs
    else
        IFS=' ' read -r -a arr <<< "$input"
        backup_dirs "${arr[@]}"
    fi
}

#################################
# 批量恢复（增加明确提示）
#################################
restore_backup(){
    shopt -s nullglob
    files=($(ls -1t "$BACKUP_DIR"/*.{tar.gz,zip} 2>/dev/null))
    [ ${#files[@]} -eq 0 ] && { echo -e "${YELLOW}❌ 没有找到可恢复的备份文件。${RESET}"; return; }

    echo -e "${YELLOW}请选择要恢复的备份文件编号：${RESET}"
    for i in "${!files[@]}"; do
        echo "$i) $(basename "${files[$i]}")"
    done

    read -p "选择编号(空格分隔多个): " input
    [ -z "$input" ] && { echo -e "${YELLOW}操作已取消。${RESET}"; return; }
    IFS=' ' read -r -a choose <<< "$input"

    for idx in "${choose[@]}"; do
        # 检查输入的索引是否有效
        if [ -z "${files[$idx]}" ]; then
            echo -e "${RED}❌ 编号 [$idx] 无效，跳过。${RESET}"
            continue
        fi
        
        f="${files[$idx]}"
        filename=$(basename "$f")
        echo -e "${YELLOW}➔ 正在恢复: $filename ...${RESET}"
        
        if [[ "$f" == *.tar.gz ]]; then
            tar -xzf "$f" -C /
        else
            unzip -oq "$f" -d /
        fi
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}🟢 成功恢复备份: $filename 到 / 目录${RESET}"
        else
            echo -e "${RED}🔴 恢复失败: $filename${RESET}"
        fi
    done
}

#################################
# Telegram设置
#################################
set_tg(){
    read -p "BOT_TOKEN: " BOT_TOKEN
    read -p "CHAT_ID: " CHAT_ID
    read -p "服务器名称: " SERVER_NAME

cat > "$TG_CONF" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
SERVER_NAME="$SERVER_NAME"
EOF

    save_conf
    echo -e "${GREEN}🟢 Telegram 通知配置已成功保存！${RESET}"
}

#################################
# 配置修改函数（均增加明确提示）
#################################
set_compress(){
    echo -e "请选择备份压缩格式："
    echo "1) tar.gz (推荐，保留权限更好)"
    echo "2) zip"
    read -p "请选择 [1-2]: " c
    if [ "$c" = "2" ]; then
        COMPRESS="zip"
    else
        COMPRESS="tar"
    fi
    save_conf
    echo -e "${GREEN}🟢 压缩格式已修改为: ${YELLOW}${COMPRESS}${RESET}"
}

set_keep(){
    read -p "请输入历史备份保留天数 (当前: ${KEEP_DAYS}天): " input
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        KEEP_DAYS=$input
        save_conf
        echo -e "${GREEN}🟢 历史备份保留天数已修改为: ${YELLOW}${KEEP_DAYS} 天${RESET}"
    else
        echo -e "${RED}❌ 输入无效，请输入纯数字！${RESET}"
    fi
}

set_local_backup_dir(){
    echo -e "当前本地备份保持目录为: ${YELLOW}${BACKUP_DIR}${RESET}"
    read -p "请输入新的绝对路径 (直接回车保持不变): " input
    if [ -n "$input" ]; then
        # 确保是绝对路径
        if [[ "$input" == /* ]]; then
            BACKUP_DIR="$input"
            mkdir -p "$BACKUP_DIR"
            save_conf
            echo -e "${GREEN}🟢 本地备份保持目录已成功修改为: ${YELLOW}${BACKUP_DIR}${RESET}"
        else
            echo -e "${RED}❌ 修改失败：必须输入以 / 开头的绝对路径！${RESET}"
        fi
    else
        echo -e "${YELLOW}未做任何修改。${RESET}"
    fi
}

#################################
# 系统环境与定时任务快照 (兼容 Alpine)
#################################
CRON_TAG="# VPSBACKUP_AUTO"

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        OS=$(uname -s)
    fi
}

get_task_count() {
    TASK_COUNT=$(crontab -l 2>/dev/null | grep -v '^\s*#' | grep -vE '^(LANG|LC_ALL|LANGUAGE)=' | grep -v 'run-parts' | grep -v '/etc/periodic' | grep -c '[^\s]')
}

list_cron_snapshot() {
    if [ "$TASK_COUNT" -gt 0 ]; then
        crontab -l 2>/dev/null | grep -v '^\s*#' | grep -vE '^(LANG|LC_ALL|LANGUAGE)=' | grep -v 'run-parts' | grep -v '/etc/periodic' | grep '[^\s]' | awk '{print "   • " $0}'
    else
        echo -e "   ${YELLOW}(暂无用户自定义的定时任务)${RESET}"
    fi
}

get_script_tasks() {
    lines=()
    while read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
}

get_backup_stats() {
    FILE_COUNT=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E '\.(tar\.gz|zip)$' | wc -l)
    if [ -d "$BACKUP_DIR" ]; then
        DISK_USAGE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    else
        DISK_USAGE="0B"
    fi
}

list_backup_snapshot() {
    if [ "$FILE_COUNT" -gt 0 ]; then
        ls -1t "$BACKUP_DIR" 2>/dev/null | grep -E '\.(tar\.gz|zip)$' | head -n 3 | awk '{print "   • " $0}'
        if [ "$FILE_COUNT" -gt 3 ]; then
            echo -e "   ${YELLOW}... 还有 $((FILE_COUNT - 3)) 个备份文件未列出${RESET}"
        fi
    else
        echo -e "   ${YELLOW}(暂无本地备份文件)${RESET}"
    fi
}

#################################
# 定时任务二级菜单
#################################
schedule_add(){
    echo -e "${GREEN}1 每天0点${RESET}"
    echo -e "${GREEN}2 每周一0点${RESET}"
    echo -e "${GREEN}3 每月1号${RESET}"
    echo -e "${GREEN}4 自定义cron${RESET}"

    read -p "选择: " t
    case $t in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "cron表达式: " cron ;;
        *) return ;;
    esac

    read -p "备份目录(空格分隔, 留空使用默认): " dirs
    if [ -n "$dirs" ]; then
        (crontab -l 2>/dev/null; \
         echo "$cron $INSTALL_PATH auto \"$dirs\" >> $BASE_DIR/cron.log 2>&1 $CRON_TAG") | crontab -
    else
        (crontab -l 2>/dev/null; \
         echo "$cron $INSTALL_PATH auto >> $BASE_DIR/cron.log 2>&1 $CRON_TAG") | crontab -
    fi

    echo -e "${GREEN}🟢 定时任务添加成功，cron日志指向: $BASE_DIR/cron.log${RESET}"
}

schedule_del_one(){
    get_script_tasks
    [ ${#lines[@]} -eq 0 ] && { echo -e "${YELLOW}❌ 没有找到通过本工具创建的定时任务。${RESET}"; return; }
    
    echo -e "${YELLOW}通过本工具创建的任务列表：${RESET}"
    for i in "${!lines[@]}"; do
        cron=$(echo "${lines[$i]}" | sed "s|$INSTALL_PATH auto.*||")
        echo "$i) $cron"
    done

    read -p "输入要删除的编号(空格分隔多个): " input
    [ -z "$input" ] && { echo -e "${YELLOW}操作已取消。${RESET}"; return; }
    IFS=' ' read -r -a choose <<< "$input"
    
    for idx in "${choose[@]}"; do
        unset 'lines[idx]'
    done
    
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; for l in "${lines[@]}"; do echo "$l"; done) | crontab
    echo -e "${GREEN}🟢 选择的定时任务已成功删除！${RESET}"
}

schedule_edit_manual(){
    echo -e "${YELLOW}提示: 即将打开系统默认编辑器编辑 crontab 配置文件。${RESET}"
    echo -e "${YELLOW}Alpine 默认使用 vi，保存退出后将自动生效。${RESET}"
    read -p "按回车打开编辑器..."
    crontab -e
    echo -e "${GREEN}🟢 手动编辑已结束。${RESET}"
}

schedule_menu(){
    while true; do
        clear
        get_os_info
        get_task_count
        
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}        ◈  Cron 定时任务管理面板  ◈      ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
        echo -e "${GREEN} 活跃任务总数 : ${YELLOW}${TASK_COUNT} 条${RESET}"
        echo -e "${GREEN}---------------------------------------${RESET}"
        echo -e "${GREEN} 📋 当前系统定时任务快照：${RESET}"
        
        list_cron_snapshot
        
        echo -e "${GREEN}---------------------------------------${RESET}"
        echo -e "${GREEN}  1) 快速添加定时任务(引导式)${RESET}"
        echo -e "${GREEN}  2) 精准删除定时任务(支持多选)${RESET}"
        echo -e "${GREEN}  3) 深度手动编辑任务(打开编辑器)${RESET}"
        echo -e "${GREEN}---------------------------------------${RESET}"
        echo -e "${GREEN}  0) 返回主菜单${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        
        echo -ne "${GREEN} 请选择操作编号: ${RESET}"
        read c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_edit_manual ;;
            0) break ;;
        esac
        read -p "回车继续..."
    done
}

#################################
# 卸载
#################################
uninstall(){
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    rm -rf "$BASE_DIR"
    rm -f /usr/local/bin/vpsbackup
    echo -e "${GREEN}🟢 已成功完全卸载本工具及相关定时任务。${RESET}"
    exit
}

#################################
# auto模式（cron专用）
#################################
if [ "$1" = "auto" ]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    load_conf

    if [ "$2" ]; then
        IFS=' ' read -r -a dirs <<< "$2"
        backup_dirs "${dirs[@]}" >> "$BASE_DIR/cron.log" 2>&1
    else
        backup_dirs >> "$BASE_DIR/cron.log" 2>&1
    fi
    exit
fi

#################################
# 主菜单
#################################
while true; do
    clear
    load_conf
    get_os_info
    get_backup_stats
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       ◈  VPS 自动化备份管理系统  ◈    ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 备份文件总数 : ${YELLOW}${FILE_COUNT} 个 (${DISK_USAGE})${RESET}"
    echo -e "${GREEN} 当前备份策略 : ${YELLOW}格式:${COMPRESS} | 保留:${KEEP_DAYS}天${RESET}"
    echo -e "${GREEN} 保持目录路径 : ${YELLOW}${BACKUP_DIR}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 📦 当前本地历史备份快照(最新3条)：${RESET}"
    
    list_backup_snapshot
    
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 立即创建系统备份(支持多目录)${RESET}"
    echo -e "${GREEN}  2) 批量恢复历史备份(引导式解压)${RESET}"
    echo -e "${GREEN}  3) 配置Telegram机器人即时通知${RESET}"
    echo -e "${GREEN}  4) 进入Cron定时任务管理面板${RESET}"
    echo -e "${GREEN}  5) 修改备份压缩格式 (tar.gz/zip)${RESET}"
    echo -e "${GREEN}  6) 修改历史备份保留天数${RESET}"
    echo -e "${GREEN}  7) 自定义本地备份保持目录${RESET}"
    echo -e "${GREEN}  8) 彻底卸载本工具及定时任务${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 退出系统${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read choice
    case $choice in
        1) create_backup ;;
        2) restore_backup ;;
        3) set_tg ;;
        4) schedule_menu ;;
        5) set_compress ;;
        6) set_keep ;;
        7) set_local_backup_dir ;;
        8) uninstall ;;
        0) exit ;;
    esac
    read -p "回车继续..."
done
