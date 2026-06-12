#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

#################################################
# caadybackup - 自动安装 + 自动更新增强版 (Caddy + 网站)
#################################################

#################################
# 远程自动安装逻辑
#################################

INSTALL_DIR="/opt/caadybackup"
LOCAL_SCRIPT="$INSTALL_DIR/caadybackup.sh"
REMOTE_URL="https://raw.githubusercontent.com/iu683/uu/main/vv.sh"

if [[ "$0" != "$LOCAL_SCRIPT" ]]; then
    mkdir -p "$INSTALL_DIR"

    curl -fsSL -o "$LOCAL_SCRIPT.tmp" "$REMOTE_URL" || {
        echo "安装失败"
        exit 1
    }

    if [[ ! -f "$LOCAL_SCRIPT" ]] || ! cmp -s "$LOCAL_SCRIPT.tmp" "$LOCAL_SCRIPT"; then
        mv "$LOCAL_SCRIPT.tmp" "$LOCAL_SCRIPT"
        chmod +x "$LOCAL_SCRIPT"
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
CRON_TAG="#caadybackup_cron"

DATA_DIR_DEFAULT="$INSTALL_DIR/data"
RETAIN_DAYS_DEFAULT=7
SERVICE_NAME_DEFAULT="$(hostname)"

mkdir -p "$INSTALL_DIR"

#################################
# Caddy 配置/数据
#################################
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
WWW_DIR="/var/www"

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
# Telegram 通知
#################################
send_tg() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    MESSAGE="[$SERVICE_NAME] $1"
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$MESSAGE" >/dev/null 2>&1
}

#################################
# 备份 Caddy 配置 + 证书 + 可执行文件
#################################
backup() {
    TIMESTAMP=$(date +%F_%H-%M-%S)
    FILE="$DATA_DIR/caddy_backup_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}开始备份 Caddy 配置、证书...${RESET}"

    # 检查文件和目录
    [[ ! -f "/usr/bin/caddy" ]] && echo -e "${RED}未找到 Caddy 可执行文件${RESET}" && return
    [[ ! -f "$CADDYFILE" ]] && echo -e "${RED}未找到 Caddyfile${RESET}" && return
    [[ ! -d "$CADDY_DATA" ]] && echo -e "${RED}未找到 Caddy 数据目录${RESET}" && return

    tar czf "$FILE" \
        /usr/bin/caddy \
        "$CADDYFILE" \
        "$CADDY_DATA" >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}备份成功：$FILE${RESET}"
        send_tg "✅ Caddy备份成功: $TIMESTAMP"
    else
        echo -e "${RED}备份失败${RESET}"
        send_tg "❌ Caddy备份失败"
    fi

    # 清理旧备份
    find "$DATA_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -delete
}

restore() {
    shopt -s nullglob
    FILE_LIST=("$DATA_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && echo -e "${RED}没有备份文件${RESET}" && return

    echo -e "${CYAN}备份列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -p "输入恢复序号: " num
    [[ ! $num =~ ^[0-9]+$ ]] && return
    FILE="${FILE_LIST[$((num-1))]}"
    [[ -z "$FILE" ]] && return

    echo -e "${YELLOW}确认恢复？将覆盖 Caddy 配置、证书 (y/n)${RESET}"
    read confirm
    [[ "$confirm" != "y" ]] && return

    # 直接恢复文件
    tar xzf "$FILE" -C /

    echo -e "${GREEN}恢复完成${RESET}"
    send_tg "🔄 Caddy 已恢复: $(basename "$FILE")"

    # 自动重启 Caddy
        echo -e "${CYAN}正在重启 Caddy (systemd)...${RESET}"

    if systemctl list-unit-files | grep -q '^caddy.service'; then
        systemctl daemon-reload
        systemctl restart caddy

        if systemctl is-active --quiet caddy; then
            echo -e "${GREEN}Caddy 重启成功${RESET}"
            send_tg "⚡ Caddy 已通过 systemd 重启"
        else
            echo -e "${RED}Caddy 启动失败，请检查日志${RESET}"
            send_tg "❌ Caddy 重启失败"
        fi
    else
        echo -e "${RED}未检测到 caddy.service，无法使用 systemd 启动${RESET}"
        send_tg "❌ 未找到 systemd 版本 Caddy"
    fi
}

#################################
# 设置 TG
#################################
set_tg() {
    read -p "服务名称: " SERVICE_NAME
    read -p "TG BOT TOKEN: " TG_TOKEN
    read -p "TG CHAT ID: " TG_CHAT_ID
    save_config
    echo -e "${GREEN}TG 已启用${RESET}"
    send_tg "✅ TG 测试成功"
}

#################################
# 设置定时任务（稳定版）
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
        4) read -p "cron表达式: " cron ;;
        *) return ;;
    esac

    crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/caadybackup_cron 2>/dev/null
    echo "$cron /usr/bin/env bash $INSTALL_DIR/caadybackup.sh auto >> $INSTALL_DIR/cron.log 2>&1 $CRON_TAG" >> /tmp/caadybackup_cron
    crontab /tmp/caadybackup_cron
    rm -f /tmp/caadybackup_cron
    echo -e "${GREEN}定时任务已设置${RESET}"
}

#################################
# 删除定时任务
#################################
remove_cron() {
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/caadybackup_cron 2>/dev/null
        crontab /tmp/caadybackup_cron
        rm -f /tmp/caadybackup_cron
        echo -e "${GREEN}定时任务已删除${RESET}"
    else
        echo -e "${YELLOW}未发现定时任务${RESET}"
    fi
}

#################################
# auto模式
#################################
if [[ "$1" == "auto" ]]; then
    backup
    exit 0
fi

#################################
# 菜单
#################################
#################################
# 菜单
#################################
while true; do
    clear
    
    # ---- 动态获取定时任务状态 ----
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        CRON_STATUS="${YELLOW}已开启${RESET}"
    else
        CRON_STATUS="${RED}已关闭${RESET}"
    fi

    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}       ◈  Caddy 备份系统  ◈        ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 📂 当前备份目录: ${YELLOW}$DATA_DIR${RESET}"
    echo -e "${GREEN} ⏳  备份保留天数: ${YELLOW}$RETAIN_DAYS 天${RESET}"
    echo -e "${GREEN} ⏰  定时任务状态: $CRON_STATUS${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1. 立即备份${RESET}"
    echo -e "${GREEN}2. 恢复备份${RESET}"
    echo -e "${GREEN}3. 设置定时任务${RESET}"
    echo -e "${GREEN}4. 删除定时任务${RESET}"
    echo -e "${GREEN}5. 设置备份目录${RESET}"
    echo -e "${GREEN}6. 设置保留天数${RESET}"
    echo -e "${GREEN}7. 设置Telegram通知${RESET}"
    echo -e "${GREEN}8. 卸载${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -p "$(echo -e ${GREEN}选择: ${RESET})" c

    case $c in
        1) backup ;;
        2) restore ;;
        3) add_cron ;;
        4) remove_cron ;;
        5) 
            read -p "新目录: " input_dir
            if [[ -n "$input_dir" ]]; then
                DATA_DIR="$input_dir"
                mkdir -p "$DATA_DIR"
                save_config
                echo -e "${GREEN}✅ 备份目录已更新${RESET}"
            else
                echo -e "${YELLOW}未输入有效目录，保持原样${RESET}"
            fi
            ;;
        6) 
            read -p "保留天数: " input_days
            if [[ "$input_days" =~ ^[0-9]+$ ]]; then
                RETAIN_DAYS="$input_days"
                save_config
                echo -e "${GREEN}✅ 保留天数已更新${RESET}"
            else
                echo -e "${RED}❌ 输入无效，请输入纯数字${RESET}"
            fi
            ;;
        7) set_tg ;;
        8)
            echo -e "${YELLOW}正在卸载...${RESET}"
            crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}卸载完成${RESET}"
            exit 0
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac

    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
done
