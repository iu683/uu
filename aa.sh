#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

#################################################
# acmebackup - ACME证书备份系统（acme.sh）
#################################################

INSTALL_DIR="/opt/acmebackup"
LOCAL_SCRIPT="$INSTALL_DIR/acmebackup.sh"
REMOTE_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/acmebackup.sh"

if [[ "$0" != "$LOCAL_SCRIPT" ]]; then
    mkdir -p "$INSTALL_DIR"

    curl -fsSL -o "$LOCAL_SCRIPT.tmp" "$REMOTE_URL" || {
        echo "下载失败"
        exit 1
    }

    if [[ ! -f "$LOCAL_SCRIPT" ]] || ! cmp -s "$LOCAL_SCRIPT.tmp" "$LOCAL_SCRIPT"; then
        mv "$LOCAL_SCRIPT.tmp" "$LOCAL_SCRIPT"
        chmod +x "$LOCAL_SCRIPT"
        echo "已安装/更新到最新版本"
    else
        rm -f "$LOCAL_SCRIPT.tmp"
    fi

    exec bash "$LOCAL_SCRIPT" "$@"
fi

#################################
# 颜色
#################################
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
RESET="\033[0m"

#################################
# 基础路径
#################################
CONFIG_FILE="$INSTALL_DIR/config.sh"
LOG_FILE="$INSTALL_DIR/backup.log"
CRON_TAG="#acmebackup_cron"

DATA_DIR_DEFAULT="$INSTALL_DIR/data"
RETAIN_DAYS_DEFAULT=7
SERVICE_NAME_DEFAULT="$(hostname)"

mkdir -p "$INSTALL_DIR"

#################################
# ACME路径
#################################
ACME_HOME="/root/.acme.sh"
SSL_DIR="/root/ssl"

#################################
# 卸载
#################################
if [[ "$1" == "--uninstall" ]]; then
    echo -e "${YELLOW}正在卸载...${RESET}"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}卸载完成${RESET}"
    exit 0
fi

#################################
# 加载配置
#################################
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

    DATA_DIR=${DATA_DIR:-$DATA_DIR_DEFAULT}
    RETAIN_DAYS=${RETAIN_DAYS:-$RETAIN_DAYS_DEFAULT}
    SERVICE_NAME=${SERVICE_NAME:-$SERVICE_NAME_DEFAULT}
}
load_config
mkdir -p "$DATA_DIR"

#################################
# 保存配置
#################################
save_config() {
cat > "$CONFIG_FILE" <<EOF
DATA_DIR="$DATA_DIR"
RETAIN_DAYS="$RETAIN_DAYS"
SERVICE_NAME="$SERVICE_NAME"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

#################################
# Telegram
#################################
send_tg() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    MESSAGE="[$SERVICE_NAME] $1"
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$MESSAGE" >/dev/null 2>&1
}

#################################
# 备份
#################################
backup() {
    TIMESTAMP=$(date +%F_%H-%M-%S)
    FILE="$DATA_DIR/acme_backup_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}开始备份 ACME证书...${RESET}"

    [[ ! -d "$ACME_HOME" ]] && echo -e "${RED}未找到 acme.sh${RESET}" && return
    [[ ! -d "$SSL_DIR" ]] && echo -e "${RED}未找到证书目录${RESET}" && return

    tar czf "$FILE" \
        "$ACME_HOME" \
        "$SSL_DIR" >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}备份成功：$FILE${RESET}"
        send_tg "✅ ACME备份成功"
    else
        echo -e "${RED}备份失败${RESET}"
        send_tg "❌ ACME备份失败"
    fi

    find "$DATA_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -delete
}

#################################
# 恢复
#################################
restore() {
    shopt -s nullglob
    FILE_LIST=("$DATA_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && echo -e "${RED}没有备份${RESET}" && return

    echo -e "${CYAN}备份列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -p "输入序号: " num
    FILE="${FILE_LIST[$((num-1))]}"

    echo -e "${YELLOW}确认恢复？(y/n)${RESET}"
    read confirm
    [[ "$confirm" != "y" ]] && return

    tar xzf "$FILE" -C /

    # 修复权限
    chmod -R 600 "$ACME_HOME"
    chmod -R 600 "$SSL_DIR"

    # 修复 cron
    crontab -l | grep -q acme.sh || "$ACME_HOME/acme.sh" --install-cronjob

    echo -e "${GREEN}恢复完成${RESET}"
    send_tg "🔄 ACME 已恢复"
}

#################################
# 定时任务
#################################
add_cron() {
    echo -e "${CYAN}1 每天0点${RESET}"
    echo -e "${CYAN}2 每周一0点${RESET}"
    echo -e "${CYAN}3 每月1号${RESET}"
    echo -e "${CYAN}4 自定义${RESET}"

    read -p "选择: " t
    case $t in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4)
            read -p "请输入 cron 表达式: " cron

            # 简单校验（防止输错）
            if [[ ! "$cron" =~ ^([0-9*/,-]+\s){4}[0-9*/,-]+$ ]]; then
                echo -e "${RED}格式错误，例如: 0 */6 * * *${RESET}"
                return
            fi
            ;;
        *) return ;;
    esac

    crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/acmebackup 2>/dev/null
    echo "$cron bash $LOCAL_SCRIPT auto >> $INSTALL_DIR/cron.log 2>&1 $CRON_TAG" >> /tmp/acmebackup
    crontab /tmp/acmebackup
    rm -f /tmp/acmebackup

    echo -e "${GREEN}定时任务已设置: $cron${RESET}"
}

remove_cron() {
    crontab -l | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}已删除定时任务${RESET}"
}

show_cron(){
    echo -e "${CYAN}当前任务:${RESET}"
    crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "无"
}
#################################
# auto
#################################
if [[ "$1" == "auto" ]]; then
    backup
    exit 0
fi

#################################
# 菜单
#################################
while true; do
    clear
    echo -e "${GREEN}==== ACME备份恢复====${RESET}"
    echo -e "${GREEN}1. 立即备份${RESET}"
    echo -e "${GREEN}2. 恢复备份${RESET}"
    echo -e "${GREEN}3. 设置定时任务${RESET}"
    echo -e "${GREEN}4. 删除定时任务${RESET}"
    echo -e "${GREEN}5. 设置备份目录${RESET}"
    echo -e "${GREEN}6. 设置保留天数${RESET}"
    echo -e "${GREEN}7. 设置Telegram${RESET}"
    echo -e "${GREEN}8. 查看定时任务${RESET}"
    echo -e "${GREEN}9. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -p "选择: " c
    case $c in
        1) backup ;;
        2) restore ;;
        3) add_cron ;;
        4) remove_cron ;;
        5) read -p "目录: " DATA_DIR; mkdir -p "$DATA_DIR"; save_config ;;
        6) read -p "天数: " RETAIN_DAYS; save_config ;;
        7)
            read -p "TG TOKEN: " TG_TOKEN
            read -p "CHAT ID: " TG_CHAT_ID
            save_config
            ;;
        8) show_cron ;;
        9) rm -rf "$INSTALL_DIR"; exit ;;
        0) exit ;;
    esac

    read -p "回车继续..."
done
