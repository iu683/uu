#!/bin/bash

#################################
# 首次运行安装（下载到 /opt）
#################################
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/zz.sh"
SCRIPT_PATH="/opt/vpsbackup/vpsbackup.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}首次运行，下载脚本到本地...${RESET}"

    mkdir -p /opt/vpsbackup

    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL" || {
        echo -e "${RED}下载失败${RESET}"
        exit 1
    }

    chmod +x "$SCRIPT_PATH"

    echo -e "${GREEN}安装完成: $SCRIPT_PATH${RESET}"

    exec bash "$SCRIPT_PATH" "$@"
fi


#################################
# 统一安装到 /opt
#################################
BASE_DIR="/opt/vpsbackup"
INSTALL_PATH="$BASE_DIR/vpsbackup.sh"
BACKUP_DIR="$BASE_DIR/backups"
TG_CONF="$BASE_DIR/.tg.conf"
CONF_FILE="$BASE_DIR/.backup.conf"

mkdir -p "$BACKUP_DIR"

#################################
# 颜色
#################################
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

#################################
# 默认配置
#################################
COMPRESS="tar"
KEEP_DAYS=7
SERVER_NAME=$(hostname)

#################################
# 读取/保存配置
#################################
load_conf(){
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -f "$TG_CONF" ] && source "$TG_CONF"
}

save_conf(){
cat > "$CONF_FILE" <<EOF
COMPRESS="$COMPRESS"
KEEP_DAYS=$KEEP_DAYS
SERVER_NAME="$SERVER_NAME"
EOF
}

#################################
# Telegram
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
# 备份核心
#################################
backup_dirs(){

    load_conf
    TS=$(date +%Y%m%d%H%M%S)

    for p in "$@"; do

        [ ! -d "$p" ] && continue

        name=$(basename "$p")

        if [ "$COMPRESS" = "tar" ]; then
            file="${name}_${TS}.tar.gz"
            tar -czf "$BACKUP_DIR/$file" "$p"
        else
            file="${name}_${TS}.zip"
            zip -rq "$BACKUP_DIR/$file" "$p"
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}完成: $file${RESET}"
            tg_send "🟢 备份成功
服务器: $SERVER_NAME
目录: $p
文件: $file"
        fi
    done

    clean_old
}

#################################
# 创建备份
#################################
create_backup(){
    read -p "目录(空格分隔 默认 /etc /home): " input

    if [ -z "$input" ]; then
        backup_dirs /etc /home
    else
        IFS=' ' read -r -a arr <<< "$input"
        backup_dirs "${arr[@]}"
    fi
}

#################################
# 列出备份
#################################
list_backups(){
    echo -e "${YELLOW}备份列表:${RESET}"
    ls -1 "$BACKUP_DIR" 2>/dev/null
}

#################################
# 批量恢复
#################################
restore_backup(){

    shopt -s nullglob
    
    files=($(ls -1t "$BACKUP_DIR"/*.{tar.gz,zip} 2>/dev/null))
    [ ${#files[@]} -eq 0 ] && return

    for i in "${!files[@]}"; do
        echo "$i) $(basename "${files[$i]}")"
    done

    read -p "选择编号: " input
    IFS=' ' read -r -a choose <<< "$input"

    for idx in "${choose[@]}"; do
        f="${files[$idx]}"

        if [[ "$f" == *.tar.gz ]]; then
            tar -xzf "$f" -C /
        else
            unzip -oq "$f" -d /
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
}

#################################
# 压缩格式/保留天数
#################################
set_compress(){
    echo "1 tar.gz"
    echo "2 zip"
    read -p "选择: " c
    [ "$c" = 2 ] && COMPRESS="zip" || COMPRESS="tar"
    save_conf
}

set_keep(){
    read -p "保留天数: " KEEP_DAYS
    save_conf
}

#################################
# 定时任务管理（支持多个 ⭐新版）
#################################

CRON_TAG="# VPSBACKUP_AUTO"

schedule_menu(){

    while true; do
        clear

        echo -e "${GREEN}=== 定时任务管理 ===${RESET}"
        echo -e "${GREEN}------------------------${RESET}"

        list_cron

        echo -e "${GREEN}------------------------${RESET}"
        echo -e "${GREEN}1. 添加任务${RESET}"
        echo -e "${GREEN}2. 删除任务${RESET}"
        echo -e "${GREEN}3. 清空全部${RESET}"
        echo -e "${GREEN}0. 返回${RESET}"

        read -p "$(echo -e ${GREEN}选择: ${RESET})" c

        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
        esac

        read -p "按回车继续..."
    done
}

#################################
# 列出cron
#################################
list_cron(){

    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")

    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "${YELLOW}暂无定时任务${RESET}"
        return
    fi

    for i in "${!lines[@]}"; do
        cron=$(echo "${lines[$i]}" | sed "s|$INSTALL_PATH auto $CRON_TAG||")
        echo "$i) $cron"
    done
}

#################################
# 添加
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

    (crontab -l 2>/dev/null; \
     echo "$cron $INSTALL_PATH auto $CRON_TAG") | crontab

    echo -e "${GREEN}添加成功${RESET}"
}

#################################
# 删除单个
#################################
schedule_del_one(){

    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
    [ ${#lines[@]} -eq 0 ] && return

    list_cron

    read -p "输入编号: " idx
    unset 'lines[idx]'

    (
        crontab -l 2>/dev/null | grep -v "$CRON_TAG"
        for l in "${lines[@]}"; do
            echo "$l"
        done
    ) | crontab

    echo -e "${GREEN}已删除${RESET}"
}
#################################
# 删除全部（修复缺失）
#################################
schedule_del_all(){
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}已清空全部定时任务${RESET}"
}

#################################
# 卸载
#################################
uninstall(){
    schedule_del_all
    rm -rf "$BASE_DIR"
    rm -f /usr/local/bin/vpsbackup
    echo -e "${GREEN}已完全卸载${RESET}"
    exit
}

#################################
# auto模式
#################################
if [ "$1" = "auto" ]; then
    backup_dirs /etc /home
    exit
fi



#################################
# 菜单
#################################
while true; do
    clear
    load_conf

    echo -e "${GREEN}=== 系统备份功能 ===${RESET}"
    echo -e "${GREEN}------------------------${RESET}"

    list_backups

    echo -e "${GREEN}------------------------${RESET}"
    echo -e "${YELLOW}格式:${COMPRESS} | 保留:${KEEP_DAYS}天 | 目录:$BASE_DIR${RESET}"
    echo -e "${GREEN}------------------------${RESET}"

    echo -e "${GREEN}1. 创建备份${RESET}"
    echo -e "${GREEN}2. 恢复备份${RESET}"
    echo -e "${GREEN}3. Telegram设置${RESET}"
    echo -e "${GREEN}4. 定时任务${RESET}"
    echo -e "${GREEN}5. 压缩格式${RESET}"
    echo -e "${GREEN}6. 保留天数${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice

    case $choice in
        1) create_backup ;;
        2) restore_backup ;;
        3) set_tg ;;
        4) schedule_menu ;;
        5) set_compress ;;
        6) set_keep ;;
        7) uninstall ;;
        0) exit ;;
    esac

    read -p "回车继续..."
done
