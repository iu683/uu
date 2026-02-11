#!/usr/bin/env bash
# =============================================
# VPS 管理脚本 – 多目录备份 + TG通知 + 定时任务 + 自更新
# =============================================

BASE_DIR="/opt/vps_manager"
SCRIPT_PATH="$BASE_DIR/vps_manager.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/uu.sh"
CONFIG_FILE="$BASE_DIR/config"
TMP_DIR="$BASE_DIR/tmp"
mkdir -p "$BASE_DIR" "$TMP_DIR"

# 配色
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"

# 默认保留天数
KEEP_DAYS=7

# 为 Cron 补充环境变量
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ================== 检查依赖并自动安装 ==================
check_dependencies(){
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}未安装 curl，请先安装 curl${RESET}"
        exit 1
    fi

    if ! command -v zip >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 zip，尝试自动安装...${RESET}"
        if [[ -f /etc/debian_version ]]; then
            apt update && apt install -y zip
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y zip
        else
            echo -e "${RED}无法自动识别系统，请手动安装 zip${RESET}"
            exit 1
        fi

        if ! command -v zip >/dev/null 2>&1; then
            echo -e "${RED}zip 安装失败，请手动安装${RESET}"
            exit 1
        else
            echo -e "${GREEN}zip 安装成功${RESET}"
        fi
    fi
}

# ================== 配置管理 ==================
load_config(){
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    [[ -n "$KEEP_DAYS" ]] && KEEP_DAYS="$KEEP_DAYS"
}

save_config(){
    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
VPS_NAME="$VPS_NAME"
KEEP_DAYS="$KEEP_DAYS"
EOF
}

# ================== Telegram 发送 ==================
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
    # 回到主菜单
    menu

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
    # 回到主菜单
    menu
}

# ================== 上传备份（多目录） ==================
do_upload(){
    load_config

    # 检查 Telegram 配置，如果未配置则直接初始化
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${YELLOW}Telegram 未配置，正在初始化配置...${RESET}"
        init
    fi

    echo "请输入要备份的目录，多个目录用空格分隔:"
    read -rp "" TARGETS

    if [[ -z "$TARGETS" ]]; then
        echo -e "${RED}没有输入目录${RESET}"
        return
    fi

    for TARGET in $TARGETS; do
        if [[ ! -e "$TARGET" ]]; then
            echo -e "${RED}目录不存在: $TARGET${RESET}"
            continue
        fi

        DIRNAME=$(basename "$TARGET")
        ZIPFILE="$TMP_DIR/${DIRNAME}_$(date +%F_%H%M%S).zip"

        if [[ -d "$TARGET" ]]; then
            zip -r "$ZIPFILE" "$TARGET" >/dev/null
        else
            zip "$ZIPFILE" "$TARGET" >/dev/null
        fi

        if [[ -f "$ZIPFILE" ]]; then
            send_tg_file "$ZIPFILE"
            send_tg_msg "📌 [$VPS_NAME] 上传完成: $DIRNAME"
            echo -e "${GREEN}上传完成: $DIRNAME${RESET}"
        else
            echo -e "${RED}打包失败: $DIRNAME${RESET}"
        fi
    done

    # 清理超过 N 天的备份
    find "$TMP_DIR" -type f -mtime +$KEEP_DAYS -name "*.zip" -exec rm -f {} \;
    echo -e "${YELLOW}已清理超过 $KEEP_DAYS 天的旧备份${RESET}"

    # 回到主菜单
    menu
}


# ================== 自动上传（Cron 触发） ==================
auto_upload(){
    load_config
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${RED}Telegram 未配置，定时任务不会上传${RESET}"
        exit 1
    fi

    DEFAULT_DIRS="$1"
    if [[ -z "$DEFAULT_DIRS" ]]; then
        echo -e "${RED}未指定目录参数，定时任务不会上传${RESET}"
        exit 1
    fi

    for DIR in $DEFAULT_DIRS; do
        if [[ ! -e "$DIR" ]]; then
            echo -e "${RED}目录不存在: $DIR${RESET}"
            continue
        fi
        DIRNAME=$(basename "$DIR")
        ZIPFILE="$TMP_DIR/${DIRNAME}_$(date +%F_%H%M%S).zip"
        zip -r "$ZIPFILE" "$DIR" >/dev/null

        if [[ -f "$ZIPFILE" ]]; then
            send_tg_file "$ZIPFILE"
            send_tg_msg "📌 [$VPS_NAME] 自动备份完成: $DIRNAME"
            echo -e "${GREEN}自动备份完成: $DIRNAME${RESET}"
        else
            echo -e "${RED}打包失败: $DIRNAME${RESET}"
        fi
    done

    find "$TMP_DIR" -type f -mtime +$KEEP_DAYS -name "*.zip" -exec rm -f {} \;
}

# ================== 定时任务管理 ==================
setup_cron_job(){
    echo -e "${GREEN}===== 定时任务管理 =====${RESET}"
    echo -e "${GREEN}1) 每天 0点${RESET}"
    echo -e "${GREEN}2) 每周一 0点${RESET}"
    echo -e "${GREEN}3) 每月 1号 0点${RESET}"
    echo -e "${GREEN}4) 每5分钟${RESET}"
    echo -e "${GREEN}5) 每10分钟${RESET}"
    echo -e "${GREEN}6) 自定义 Cron 表达式${RESET}"
    echo -e "${GREEN}7) 删除本脚本所有任务${RESET}"
    echo -e "${GREEN}8) 查看当前任务${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
    read -rp "请选择: " choice

    CRON_DIRS_FILE="$BASE_DIR/cron_dirs"  # 保存定时备份目录
    CRON_CMD=""

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
            echo -e "${GREEN}已删除所有本脚本定时任务${RESET}"
            return ;;
        8)
            echo -e "${YELLOW}当前定时任务:${RESET}"
            crontab -l 2>/dev/null | grep "$SCRIPT_PATH"
            return ;;
        0) return ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            return ;;
    esac

    # 提示输入备份目录
    read -rp "请输入定时备份目录(多个用空格分隔): " BACKUP_DIRS
    if [[ -z "$BACKUP_DIRS" ]]; then
        echo -e "${RED}未输入目录，取消设置${RESET}"
        return
    fi

    # 保存目录到文件
    echo "$BACKUP_DIRS" > "$CRON_DIRS_FILE"

    CRON_CMD="bash $SCRIPT_PATH auto_upload '$BACKUP_DIRS'"

    # 设置定时任务
    if [[ -n "$CRON_TIME" ]]; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
        (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -
        echo -e "${GREEN}已设置定时任务:${RESET} $CRON_TIME $CRON_CMD"
    fi
    menu
}

# ================== 查看定时备份目录 ==================
view_cron_dirs(){
    CRON_DIRS_FILE="$BASE_DIR/cron_dirs"
    if [[ -f "$CRON_DIRS_FILE" ]]; then
        echo -e "${GREEN}已设置定时备份目录:${RESET}"
        cat "$CRON_DIRS_FILE"
    else
        echo -e "${YELLOW}暂无定时备份目录${RESET}"
    fi
    echo
    read -rp "按回车返回菜单..." dummy
    menu
}

# ================== 脚本自更新 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak" 2>/dev/null
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}脚本更新完成${RESET}"
    # 回到主菜单
    menu
}

# ================== 卸载 ==================
uninstall(){
    read -rp "确认卸载脚本并删除所有定时任务? (y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
        rm -rf "$BASE_DIR"
        echo -e "${RED}已卸载${RESET}"
    fi
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
    echo -e "${GREEN}7) 更新${RESET}"
    echo -e "${GREEN}8) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}请选择: ${RESET})" choice

    case $choice in
        1) do_upload ;;
        2) init ;;
        3) rm -rf "$TMP_DIR"/* && echo -e "${YELLOW}已删除临时文件${RESET}" ;;
        4) setup_cron_job ;;
        5) set_keep_days ;;
        6) view_cron_dirs ;;
        7) download_script ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}


# ================== 执行入口 ==================
check_dependencies

if [[ "$1" == "auto_upload" ]]; then
    auto_upload "$2"
else
    # 仅在脚本不存在时下载
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo -e "${YELLOW}首次运行，正在下载最新脚本...${RESET}"
        mkdir -p "$(dirname "$SCRIPT_PATH")"
        curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}首次下载完成${RESET}"
    fi

    menu  # 进入主菜单
fi
