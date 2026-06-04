#!/usr/bin/env bash
# 强制使用 bash 运行
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

#################################################
# caadybackup - 自动安装 + 自动更新增强版 (Caddy + 网站)
# 适配说明: 已全面兼容 Alpine Linux (OpenRC) 架构
#################################################

#################################
# 远程自动安装逻辑
#################################
INSTALL_DIR="/opt/caadybackup"
LOCAL_SCRIPT="$INSTALL_DIR/caadybackup.sh"
REMOTE_URL="bash <(curl -sL https://raw.githubusercontent.com/iu683/uu/main/aa.sh)"

# 环境依赖检测（针对 Alpine 精简环境进行动态补全）
if [ -f /etc/alpine-release ]; then
    INIT_DEPS=()
    command -v curl >/dev/null 2>&1 || INIT_DEPS+=("curl")
    command -v bash >/dev/null 2>&1 || INIT_DEPS+=("bash")
    command -v tar >/dev/null 2>&1 || INIT_DEPS+=("tar")
    
    if [ ${#INIT_DEPS[@]} -ne 0 ]; then
        apk update -q && apk add -q "${INIT_DEPS[@]}"
    fi
fi

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
CRON_TAG="#caadybackup_cron"

DATA_DIR_DEFAULT="$INSTALL_DIR/data"
RETAIN_DAYS_DEFAULT=7
SERVICE_NAME_DEFAULT="$(hostname)"

mkdir -p "$INSTALL_DIR"

#################################
# Caddy 配置/数据路径动态适配
#################################
CADDYFILE="/etc/caddy/Caddyfile"

# 智能兼容：探测 Alpine APK 默认路径、原生独立运行路径与标准路径
if [ -d "/var/lib/caddy/.local/share/caddy" ]; then
    CADDY_DATA="/var/lib/caddy/.local/share/caddy"
elif [ -d "/root/.local/share/caddy" ]; then
    CADDY_DATA="/root/.local/share/caddy"
else
    CADDY_DATA="$HOME/.local/share/caddy"
fi

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
# 备份 Caddy 配置 + 证书
#################################
backup() {
    # 适配 BusyBox 版本的 date 命令，移除了可能冲突的复杂格式
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    FILE="$DATA_DIR/caddy_backup_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}开始备份 Caddy 配置、证书...${RESET}"

    # 路径健壮性校验
    local caddy_bin=""
    if [ -f "/usr/sbin/caddy" ]; then caddy_bin="/usr/sbin/caddy"; else caddy_bin="/usr/bin/caddy"; fi

    [[ ! -f "$caddy_bin" ]] && echo -e "${RED}未找到 Caddy 可执行文件${RESET}" && return
    [[ ! -f "$CADDYFILE" ]] && echo -e "${RED}未找到 Caddyfile${RESET}" && return
    [[ ! -d "$CADDY_DATA" ]] && echo -e "${RED}未找到 Caddy 数据目录${RESET}" && return

    # 使用 -P 参数防止 BusyBox/GNU tar 清除根路径首斜杠引发恢复错位
    tar -czPf "$FILE" \
        "$caddy_bin" \
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
    find "$DATA_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -delete 2>/dev/null || true
}

#################################
# 恢复备份
#################################
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

    # 使用 -P 确保绝对路径无缝覆盖回原目录
    tar -xzPf "$FILE" -C /

    echo -e "${GREEN}恢复完成${RESET}"
    send_tg "🔄 Caddy 已恢复: $(basename "$FILE")"

    # ==================== Alpine + Systemd 双架构智能重启 ====================
    echo -e "${CYAN}正在尝试重启 Caddy 服务...${RESET}"

    if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
        # 1. 优先适配 Alpine OpenRC 架构
        echo -e "${CYAN}检测到 Alpine 环境，正在通过 OpenRC 管理器重启...${RESET}"
        if rc-service caddy status 2>/dev/null | grep -q "started"; then
            rc-service caddy restart
        else
            rc-service caddy start || true
        fi
        
        # 针对脚本独立原生运行模式进行兼容复活
        if pgrep -x caddy >/dev/null 2>&1; then
            echo -e "${GREEN}Caddy 重启成功${RESET}"
            send_tg "⚡ Caddy 已通过 OpenRC/原生 方式重启"
        else
            # 如果没有进程，尝试使用 caddy 命令直接拉起后台
            killall -9 caddy >/dev/null 2>&1 || true
            if caddy start --config "$CADDYFILE" >/dev/null 2>&1; then
                echo -e "${GREEN}Caddy 独立原生拉起成功${RESET}"
                send_tg "⚡ Caddy 已通过独立原生进程重启"
            else
                echo -e "${RED}Caddy 启动失败，请检查 Caddyfile 配置${RESET}"
                send_tg "❌ Caddy 重启失败"
            fi
        fi

    elif command -v systemctl >/dev/null 2>&1; then
        # 2. 传统 Systemd 架构兜底
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
            echo -e "${RED}未检测到 caddy.service${RESET}"
        fi
    else
        # 3. 无系统管理器时的原生冷启动兜底
        echo -e "${YELLOW}未检测到系统服务管理器，正在执行独立二进制原生唤醒...${RESET}"
        killall -9 caddy >/dev/null 2>&1 || true
        if caddy start --config "$CADDYFILE" >/dev/null 2>&1; then
            echo -e "${GREEN}Caddy 原生唤醒成功${RESET}"
        else
            echo -e "${RED}Caddy 唤醒失败${RESET}"
        fi
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
        * ) return ;;
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
while true; do
    clear
    echo -e "${CYAN}==== Caddy 备份系统 ====${RESET}"
    echo -e "${GREEN}1. 立即备份${RESET}"
    echo -e "${GREEN}2. 恢复备份${RESET}"
    echo -e "${GREEN}3. 设置定时任务${RESET}"
    echo -e "${GREEN}4. 删除定时任务${RESET}"
    echo -e "${GREEN}5. 设置备份目录(当前: $DATA_DIR)${RESET}"
    echo -e "${GREEN}6. 设置保留天数(当前: $RETAIN_DAYS 天)${RESET}"
    echo -e "${GREEN}7. 设置Telegram通知${RESET}"
    echo -e "${GREEN}8. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -p "$(echo -e ${GREEN}选择: ${RESET})" c
    case $c in
        1) backup ;;
        2) restore ;;
        3) add_cron ;;
        4) remove_cron ;;
        5) read -p "新目录: " DATA_DIR; mkdir -p "$DATA_DIR"; save_config ;;
        6) read -p "保留天数: " RETAIN_DAYS; save_config ;;
        7) set_tg ;;
        8)
            echo -e "${YELLOW}正在卸载...${RESET}"
            crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}卸载完成${RESET}"
            exit 0
            ;;
        0) exit 0 ;;
    esac

    read -p "$(echo -e ${GREEN}回车继续....${RESET})"
done
