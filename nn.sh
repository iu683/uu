#!/usr/bin/env bash
# 兼容 Alpine 的环境变量
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=${HOME:-/root}

#################################################
# nginxbackup - 自动安装 + 自动更新增强版
#################################################

INSTALL_DIR="/opt/nginxbackup"
LOCAL_SCRIPT="$INSTALL_DIR/nginxbackup.sh"
REMOTE_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"

# 检测并安装依赖（专门针对 Alpine 增强）
if [ -f /etc/alpine-release ]; then
    # Alpine 默认没有 bash, curl, tar, findutils(标准find), certbot/letsencrypt 路径兼容
    # 提示：如果作为容器运行，确保已安装 bash
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        echo "检测到 Alpine 系统，正在安装必要依赖..."
        apk update && apk add --no-cache curl tar bash findutils
    fi
fi

#################################
# 远程自动安装逻辑
#################################
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
CRON_TAG="nginxbackup_cron" 

DATA_DIR_DEFAULT="$INSTALL_DIR/data"
RETAIN_DAYS_DEFAULT=7
SERVICE_NAME_DEFAULT="$(hostname 2>/dev/null || echo 'Alpine-Server')"

mkdir -p "$INSTALL_DIR"

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
# 备份
#################################
backup() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${RED}未安装 nginx${RESET}"
        return
    fi

    TIMESTAMP=$(date +%F_%H-%M-%S)
    FILE="$DATA_DIR/nginx_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}检查 nginx 配置...${RESET}"
    nginx -t >/dev/null 2>&1 || {
        echo -e "${RED}nginx 配置错误${RESET}"
        send_tg "❌ 备份失败（配置错误）"
        return
    }

    echo -e "${CYAN}开始备份...${RESET}"

    # Alpine/BusyBox 的 tar 不支持某些 GNU 特异参数，这里采用通用打包方式
    # 同时检查目录是否存在，不存在则跳过，避免 tar 报错
    TARGET_DIRS=""
    [[ -d "/etc/nginx" ]] && TARGET_DIRS="$TARGET_DIRS /etc/nginx"
    [[ -d "/etc/letsencrypt" ]] && TARGET_DIRS="$TARGET_DIRS /etc/letsencrypt"

    if [[ -z "$TARGET_DIRS" ]]; then
        echo -e "${RED}未找到备份目标目录${RESET}"
        return
    fi

    tar czf "$FILE" $TARGET_DIRS >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}备份成功${RESET}"
        send_tg "✅ nginx备份成功: $TIMESTAMP"
    else
        echo -e "${RED}备份失败${RESET}"
        send_tg "❌ nginx备份失败"
    fi

    # 清理旧备份：BusyBox 的 find 不支持 +7 这种写法或 -delete 参数！
    # 兼容处理：使用标准 find 语法（或由 apk 安装的 findutils 提供支持）
    find "$DATA_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -exec rm -f {} \;
}

#################################
# 恢复
#################################
restore() {
    shopt -s nullglob
    FILE_LIST=("$DATA_DIR"/*.tar.gz)

    if [[ ${#FILE_LIST[@]} -eq 0 ]]; then
        echo -e "${RED}没有备份文件${RESET}"
        return
    fi

    echo -e "${CYAN}备份列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -p "输入恢复序号: " num
    [[ ! $num =~ ^[0-9]+$ ]] && return

    FILE="${FILE_LIST[$((num-1))]}"
    [[ -z "$FILE" ]] && return

    echo -e "${YELLOW}确认恢复？将覆盖当前环境 (y/n)${RESET}"
    read confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}正在停止 Nginx 业务进程...${RESET}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service nginx stop >/dev/null 2>&1 || true
    elif [ -f /etc/init.d/nginx ]; then
        /etc/init.d/nginx stop 2>/dev/null || true
    fi

    # 兼容清空旧路径，防止解压软链接时死锁或覆盖失败
    echo -e "${YELLOW}正在解压还原快照数据...${RESET}"
    tar xzf "$FILE" --overwrite -C / 2>/dev/null || tar xzf "$FILE" -C /

    echo -e "${CYAN}正在对恢复后的配置执行语法校验...${RESET}"
    if nginx -t >/dev/null 2>&1; then
        echo -e "${YELLOW}正在重启拉起 Nginx 服务...${RESET}"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start nginx
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service nginx start
        elif [ -f /etc/init.d/nginx ]; then
            /etc/init.d/nginx start
        fi
        echo -e "${GREEN}✅ 完美恢复完成！环境已恢复上线。${RESET}"
        send_tg "🔄 Nginx 环境已成功回滚恢复至快照: $(basename "$FILE")"
    else
        echo -e "${RED}❌ 致命：恢复后的配置存在语法错误，为了安全未强行拉起服务，请核实！${RESET}"
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
# 设置定时任务（兼容 BusyBox crontab）
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

    # BusyBox 的 crontab 不支持直接追加文件，先安全导出
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/nginxbackup_cron 2>/dev/null

    # 写入新任务，把 TAG 留在前面或作为注释，确保 BusyBox 不会解析错误
    # 注意：BusyBox cron 的末尾加 # 注释在某些老版本会报错，改成标准环境变量或标准格式
    echo "$cron /usr/bin/env bash $INSTALL_DIR/nginxbackup.sh auto >> $INSTALL_DIR/cron.log 2>&1 #$CRON_TAG" >> /tmp/nginxbackup_cron

    crontab /tmp/nginxbackup_cron
    rm -f /tmp/nginxbackup_cron

    echo -e "${GREEN}定时任务已设置${RESET}"
}

#################################
# 删除定时任务
#################################
remove_cron() {
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/nginxbackup_cron 2>/dev/null
        crontab /tmp/nginxbackup_cron
        rm -f /tmp/nginxbackup_cron
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
    echo -e "${CYAN}==== Nginx 备份系统 ====${RESET}"
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
