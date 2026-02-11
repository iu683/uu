#!/usr/bin/env bash
# =============================================
# VPS 管理脚本 – 多目录备份 + TG通知 + 定时任务 + 自更新
# =============================================

BASE_DIR="/opt/vps_manager"
SCRIPT_PATH="$BASE_DIR/vps_manager.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
CONFIG_FILE="$BASE_DIR/config"
TMP_DIR="$BASE_DIR/tmp"
mkdir -p "$BASE_DIR" "$TMP_DIR"

# 配色
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"

# 默认保留天数
KEEP_DAYS=7
# 默认压缩格式
ARCHIVE_FORMAT="tar"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ================== 检查依赖 ==================
check_dependencies(){
    for cmd in curl tar zip; do
        if ! command -v $cmd >/dev/null 2>&1; then
            if [[ "$cmd" == "zip" ]]; then
                echo -e "${YELLOW}未检测到 zip，尝试自动安装...${RESET}"
                if [[ -f /etc/debian_version ]]; then
                    apt update && apt install -y zip
                elif [[ -f /etc/redhat-release ]]; then
                    yum install -y zip
                else
                    echo -e "${RED}无法自动识别系统，请手动安装 zip${RESET}"
                    exit 1
                fi
            else
                echo -e "${RED}未安装 $cmd，请先安装${RESET}"
                exit 1
            fi
        fi
    done
}

# ================== 配置管理 ==================
load_config(){
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    [[ -n "$KEEP_DAYS" ]] && KEEP_DAYS="$KEEP_DAYS"
    [[ -n "$ARCHIVE_FORMAT" ]] && ARCHIVE_FORMAT="$ARCHIVE_FORMAT"
}

save_config(){
    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
VPS_NAME="$VPS_NAME"
KEEP_DAYS="$KEEP_DAYS"
ARCHIVE_FORMAT="$ARCHIVE_FORMAT"
EOF
}

# ================== Telegram ==================
send_tg_msg(){
    local msg="$1"
    curl -s -F chat_id="$CHAT_ID" -F text="$msg" \
         "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" > /dev/null
}

send_tg_file(){
    local file="$1"
    if [[ -f "$file" ]]; then
        curl -s -F chat_id="$CHAT_ID" -F document=@"$file" \
             "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" > /dev/null
    else
        echo -e "${RED}文件不存在，未上传: $file${RESET}"
    fi
}

# ================== 初始化配置 ==================
init(){
    read -rp "请输入 Telegram Bot Token: " BOT_TOKEN
    read -rp "请输入 Chat ID: " CHAT_ID
    read -rp "请输入 VPS 名称（可为空）: " VPS_NAME
    save_config
    echo -e "${GREEN}配置完成!${RESET}"
}

# ================== 设置保留天数 ==================
set_keep_days(){
    read -rp "请输入保留备份的天数（当前 $KEEP_DAYS 天）: " days
    if [[ "$days" =~ ^[0-9]+$ ]]; then
        KEEP_DAYS="$days"
        save_config
        echo -e "${GREEN}已将备份保留天数设置为 $KEEP_DAYS 天${RESET}"
    else
        echo -e "${RED}输入无效，请输入正整数${RESET}"
    fi
    menu
}

# ================== 设置压缩格式 ==================
set_archive_format(){
    echo -e "${GREEN}请选择压缩格式 (当前: $ARCHIVE_FORMAT)${RESET}"
    echo -e "${GREEN}1) tar.gz（默认）${RESET}"
    echo -e "${GREEN}2) zip${RESET}"
    read -rp "请选择: " choice
    case $choice in
        2) ARCHIVE_FORMAT="zip" ;;
        *) ARCHIVE_FORMAT="tar" ;;
    esac
    save_config
    echo -e "${GREEN}已设置压缩格式为 $ARCHIVE_FORMAT${RESET}"
    menu
}

# ================== 上传备份 ==================
do_upload(){
    load_config

    # Telegram 未配置则初始化
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${YELLOW}Telegram 未配置，正在初始化配置...${RESET}"
        init
        echo -e "${GREEN}Telegram 配置完成，继续上传${RESET}"
    fi

    while true; do
        echo "请输入要备份的目录，多个目录用空格分隔 (回车返回主菜单):"
        read -rp "" TARGETS

        [[ -z "$TARGETS" ]] && menu && return

        for TARGET in $TARGETS; do
            if [[ ! -e "$TARGET" ]]; then
                echo -e "${RED}目录不存在: $TARGET${RESET}"
                continue
            fi

            DIRNAME=$(basename "$TARGET")
            TIMESTAMP=$(date +%F_%H%M%S)
            ZIPFILE="$TMP_DIR/${DIRNAME}_$TIMESTAMP"

            # 压缩
            if [[ "$ARCHIVE_FORMAT" == "tar" ]]; then
                ZIPFILE="$ZIPFILE.tar.gz"
                tar -czf "$ZIPFILE" -C "$(dirname "$TARGET")" "$DIRNAME" >/dev/null
            else
                ZIPFILE="$ZIPFILE.zip"
                zip -r "$ZIPFILE" "$TARGET" >/dev/null
            fi

            if [[ -f "$ZIPFILE" ]]; then
                send_tg_file "$ZIPFILE"
                send_tg_msg "📌 [$VPS_NAME] 上传完成: $DIRNAME"
                echo -e "${GREEN}上传完成: $DIRNAME${RESET}"
            else
                echo -e "${RED}打包失败: $DIRNAME${RESET}"
            fi
        done
    done
}

# ================== 自动上传 ==================
auto_upload(){
    load_config
    [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && echo -e "${RED}Telegram 未配置，定时任务不会上传${RESET}" && return
    DEFAULT_DIRS="$1"
    [[ -z "$DEFAULT_DIRS" ]] && echo -e "${YELLOW}未指定目录参数，定时任务不会上传${RESET}" && return

    for DIR in $DEFAULT_DIRS; do
        [[ ! -e "$DIR" ]] && echo -e "${RED}目录不存在: $DIR${RESET}" && continue
        DIRNAME=$(basename "$DIR")
        TIMESTAMP=$(date +%F_%H%M%S)
        ZIPFILE="$TMP_DIR/${DIRNAME}_$TIMESTAMP"

        if [[ "$ARCHIVE_FORMAT" == "tar" ]]; then
            ZIPFILE="$ZIPFILE.tar.gz"
            tar -czf "$ZIPFILE" -C "$(dirname "$DIR")" "$DIRNAME" >/dev/null
        else
            ZIPFILE="$ZIPFILE.zip"
            zip -r "$ZIPFILE" "$DIR" >/dev/null
        fi

        if [[ -f "$ZIPFILE" ]]; then
            send_tg_file "$ZIPFILE"
            send_tg_msg "📌 [$VPS_NAME] 自动备份完成: $DIRNAME"
            echo -e "${GREEN}自动备份完成: $DIRNAME${RESET}"
        else
            echo -e "${RED}打包失败: $DIRNAME${RESET}"
        fi
    done

    find "$TMP_DIR" -type f -mtime +$KEEP_DAYS -name "*.tar.gz" -o -name "*.zip" -exec rm -f {} \;
}

# ================== 定时任务管理 ==================
setup_cron_job(){
    CRON_DIRS_FILE="$BASE_DIR/cron_dirs"
    echo -e "${GREEN}===== 定时任务管理 =====${RESET}"
    echo -e "${GREEN}1) 每天 0点${RESET}"
    echo -e "${GREEN}2) 每周一 0点${RESET}"
    echo -e "${GREEN}3) 每月 1号 0点${RESET}"
    echo -e "${GREEN}4) 每5分钟${RESET}"
    echo -e "${GREEN}5) 每10分钟${RESET}"
    echo -e "${GREEN}6) 自定义 Cron 表达式${RESET}"
    echo -e "${GREEN}7) 删除所有任务${RESET}"
    echo -e "${GREEN}8) 查看任务${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
    read -rp "请选择: " choice

    case $choice in
        1) CRON_TIME="0 0 * * *" ;;
        2) CRON_TIME="0 0 * * 1" ;;
        3) CRON_TIME="0 0 1 * *" ;;
        4) CRON_TIME="*/5 * * * *" ;;
        5) CRON_TIME="*/10 * * * *" ;;
        6) read -rp "请输入 Cron 表达式 (分 时 日 月 周): " CRON_TIME ;;
        7)
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
            rm -f "$CRON_DIRS_FILE"
            echo -e "${GREEN}已删除所有任务${RESET}"
            menu; return ;;
        8)
            echo -e "${YELLOW}当前任务:${RESET}"
            crontab -l 2>/dev/null | grep "$SCRIPT_PATH"
            read -rp "回车返回菜单..." dummy
            menu; return ;;
        0) menu; return ;;
        *) echo -e "${RED}无效选项${RESET}"; menu; return ;;
    esac

    read -rp "请输入备份目录(多个用空格分隔): " BACKUP_DIRS
    [[ -z "$BACKUP_DIRS" ]] && echo -e "${YELLOW}未输入目录，返回菜单${RESET}" && menu && return
    echo "$BACKUP_DIRS" > "$CRON_DIRS_FILE"

    CRON_CMD="bash $SCRIPT_PATH auto_upload '$BACKUP_DIRS'"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -
    echo -e "${GREEN}已设置定时任务:${RESET} $CRON_TIME $CRON_CMD"
    menu
}

# ================== 主菜单 ==================
menu(){
    load_config
    echo -e "${GREEN}===== VPS TG备份菜单 =====${RESET}"
    echo -e "${GREEN}1) 上传文件目录到Telegram${RESET}"
    echo -e "${GREEN}2) 修改Telegram配置${RESET}"
    echo -e "${GREEN}3) 删除临时文件${RESET}"
    echo -e "${GREEN}4) 定时任务管理${RESET}"
    echo -e "${GREEN}5) 设置保留备份天数(当前: $KEEP_DAYS 天)${RESET}"
    echo -e "${GREEN}6) 查看已添加的定时备份目录${RESET}"
    echo -e "${GREEN}7) 设置压缩格式(当前: $ARCHIVE_FORMAT)${RESET}"
    echo -e "${GREEN}8) 更新脚本${RESET}"
    echo -e "${GREEN}9) 卸载脚本${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择: ${RESET})" choice

    case $choice in
        1) do_upload ;;
        2) init ;;
        3) rm -rf "$TMP_DIR"/* && echo -e "${YELLOW}已删除临时文件${RESET}" ;;
        4) setup_cron_job ;;
        5) set_keep_days ;;
        6) [[ -f "$BASE_DIR/cron_dirs" ]] && cat "$BASE_DIR/cron_dirs" || echo -e "${YELLOW}暂无定时目录${RESET}" ;;
        7) set_archive_format ;;
        8)
            curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo -e "${GREEN}脚本已更新${RESET}" ;;
        9)
            read -rp "确认卸载脚本并删除所有定时任务? (y/N): " yn
            [[ "$yn" =~ ^[Yy]$ ]] && crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - && rm -rf "$BASE_DIR" && echo -e "${RED}已卸载${RESET}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    menu
}

# ================== 执行入口 ==================
check_dependencies

if [[ "$1" == "auto_upload" ]]; then
    auto_upload "$2"
else
    [[ ! -f "$SCRIPT_PATH" ]] && curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    menu
fi
