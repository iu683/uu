#!/usr/bin/env bash
# =============================================
# VPS 管理脚本 – 多目录备份 + TG通知 + 定时任务 + 自更新
# =============================================

BASE_DIR="/opt/vps_manager"
SCRIPT_PATH="$BASE_DIR/vps_manager.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
CONFIG_FILE="$BASE_DIR/config"
CRON_DIRS_FILE="$BASE_DIR/cron_dirs"
TMP_DIR="$BASE_DIR/tmp"
mkdir -p "$BASE_DIR" "$TMP_DIR"

# 配色
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"

# 默认基础配置
KEEP_DAYS=7
ARCHIVE_FORMAT="tar"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ================== 检查并自动安装依赖 ==================
check_dependencies(){
    local missing_cmds=()
    for cmd in curl tar zip; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -ne 0 ]; then
        echo -e "${YELLOW}检测到缺少依赖: ${missing_cmds[*]}，正在尝试自动安装...${RESET}"
        if [[ -f /etc/alpine-release ]]; then
            apk update && apk add ca-certificates # 补充SSL证书，防止curl GitHub失败
            for cmd in "${missing_cmds[@]}"; do
                if [[ "$cmd" == "tar" ]]; then apk add tar; fi 
                if [[ "$cmd" == "zip" ]]; then apk add zip; fi
                if [[ "$cmd" == "curl" ]]; then apk add curl; fi
            done
        elif [[ -f /etc/debian_version ]]; then
            apt update && apt install -y curl tar zip ca-certificates
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y curl tar zip ca-certificates
        else
            echo -e "${RED}无法自动识别系统包管理器，请手动安装: ${missing_cmds[*]}${RESET}"
            exit 1
        fi
    fi
}

# ================== 配置管理 ==================
load_config(){
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
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

# ================== Telegram 通知 ==================
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
    read -rp "按回车键返回主菜单..." dummy
}

# ================== 设置保留天数 ==================
set_keep_days(){
    read -rp "请输入保留备份的天数（当前: $KEEP_DAYS 天）: " days
    if [[ "$days" =~ ^[0-9]+$ ]]; then
        KEEP_DAYS="$days"
        save_config
        echo -e "${GREEN}已将备份保留天数设置为 $KEEP_DAYS 天${RESET}"
    else
        echo -e "${RED}输入无效，请输入正整数${RESET}"
    fi
    read -rp "按回车键返回主菜单..." dummy
}

# ================== 设置压缩格式 ==================
set_archive_format(){
    echo -e "${GREEN}请选择压缩格式:${RESET}"
    echo -e "${GREEN}1) tar.gz${RESET}"
    echo -e "${GREEN}2) zip${RESET}"
    read -rp "请选择 (1或2): " choice
    case $choice in
        2) ARCHIVE_FORMAT="zip" ;;
        *) ARCHIVE_FORMAT="tar" ;;
    esac
    save_config
    echo -e "${GREEN}已设置压缩格式为: $ARCHIVE_FORMAT${RESET}"
    read -rp "按回车键返回主菜单..." dummy
}

# ================== 打包与上传核心 ==================
execute_backup(){
    local targets="$1"
    local prefix_msg="$2"

    for TARGET in $targets; do
        if [[ ! -e "$TARGET" ]]; then
            echo -e "${RED}目录/文件不存在: $TARGET${RESET}"
            continue
        fi

        DIRNAME=$(basename "$TARGET")
        TIMESTAMP=$(date +%F_%H%M%S)
        ZIPFILE="$TMP_DIR/${DIRNAME}_$TIMESTAMP"

        if [[ "$ARCHIVE_FORMAT" == "tar" ]]; then
            ZIPFILE="$ZIPFILE.tar.gz"
            tar -czf "$ZIPFILE" -C "$(dirname "$TARGET")" "$DIRNAME" >/dev/null
        else
            ZIPFILE="$ZIPFILE.zip"
            zip -r "$ZIPFILE" "$TARGET" >/dev/null
        fi

        if [[ -f "$ZIPFILE" ]]; then
            send_tg_file "$ZIPFILE"
            send_tg_msg "📌 [$VPS_NAME] ${prefix_msg}备份完成: $DIRNAME"
            echo -e "${GREEN}${prefix_msg}备份完成: $DIRNAME${RESET}"
        else
            echo -e "${RED}打包失败: $DIRNAME${RESET}"
        fi
    done
}

# ================== 手动上传 ==================
do_upload(){
    load_config
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        echo -e "${YELLOW}Telegram 未配置，正在初始化配置...${RESET}"
        init
    fi

    while true; do
        echo "请输入要备份的目录，多个目录用空格分隔 (回车返回主菜单):"
        read -rp "" TARGETS
        [[ -z "$TARGETS" ]] && break
        execute_backup "$TARGETS" "手动"
    done
}

# ================== 自动上传 (Cron 调用入口) ==================
auto_upload(){
    load_config
    [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && echo -e "${RED}Telegram 未配置，定时任务不会上传${RESET}" && return
    
    local targets="$1"
    [[ -z "$targets" ]] && [[ -f "$CRON_DIRS_FILE" ]] && targets=$(cat "$CRON_DIRS_FILE")
    [[ -z "$targets" ]] && echo -e "${YELLOW}未指定目录，定时任务退出${RESET}" && return

    execute_backup "$targets" "自动"
    find "$TMP_DIR" -type f -mtime +$KEEP_DAYS \( -name "*.tar.gz" -o -name "*.zip" \) -exec rm -f {} \;
}

# ================== 定时任务管理 ==================
setup_cron_job(){
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}     ◈    定时任务管理    ◈       ${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}1) 每天0点${RESET}"
    echo -e "${GREEN}2) 每周一0点${RESET}"
    echo -e "${GREEN}3) 每月1号0点${RESET}"
    echo -e "${GREEN}4) 每5分钟${RESET}"
    echo -e "${GREEN}5) 每10分钟${RESET}"
    echo -e "${GREEN}6) 自定义Cron表达式${RESET}"
    echo -e "${GREEN}7) 删除所有定时任务${RESET}"
    echo -e "${GREEN}8) 查看当前定时命令${RESET}"
    echo -e "${GREEN}0) 返回${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    read -rp "请选择: " choice

    case $choice in
        1) CRON_TIME="0 0 * * *" ;;
        2) CRON_TIME="0 0 * * 1" ;;
        3) CRON_TIME="0 0 1 * *" ;;
        4) CRON_TIME="*/5 * * * *" ;;
        5) CRON_TIME="*/10 * * * *" ;;
        6) read -rp "请输入 Cron 表达式: " CRON_TIME ;;
        7)
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
            rm -f "$CRON_DIRS_FILE"
            echo -e "${GREEN}已删除所有相关定时任务${RESET}"
            read -rp "按回车键返回主菜单..." dummy
            return ;;
        8)
            echo -e "${YELLOW}当前配置的 Cron 任务:${RESET}"
            crontab -l 2>/dev/null | grep "$SCRIPT_PATH" || echo "无相关定时任务"
            read -rp "按回车键返回主菜单..." dummy
            return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; return ;;
    esac

    read -rp "请输入备份目录(多个用空格分隔): " BACKUP_DIRS
    [[ -z "$BACKUP_DIRS" ]] && echo -e "${YELLOW}未输入目录，取消设置${RESET}" && return
    echo "$BACKUP_DIRS" > "$CRON_DIRS_FILE"

    local bash_path && bash_path=$(command -v bash || echo "/bin/bash")
    CRON_CMD="$bash_path $SCRIPT_PATH auto_upload"
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -
    echo -e "${GREEN}定时任务设置成功! 表达式: $CRON_TIME${RESET}"

    if [[ -f /etc/alpine-release ]]; then
        echo -e "${YELLOW}[Alpine 提示] 请确保系统的 crond 服务已启动 (rc-service crond status)${RESET}"
    fi
    read -rp "按回车键返回主菜单..." dummy
}

# ================== 主菜单 ==================
menu(){
    while true; do
        clear 
        load_config

        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
            CRON_STATUS="${GREEN}已开启${RESET}"
        else
            CRON_STATUS="${RED}未开启${RESET}"
        fi

        if [[ "$ARCHIVE_FORMAT" == "tar" ]]; then
            FORMAT_DISPLAY="tar.gz"
        else
            FORMAT_DISPLAY="zip"
        fi

        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN}    ◈    TG 备份管理系统    ◈     ${RESET}"
        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN} 📅 备份保留天数:${RESET} ${YELLOW}${KEEP_DAYS} 天${RESET}"
        echo -e "${GREEN} 📦 默认压缩格式:${RESET} ${YELLOW}${FORMAT_DISPLAY}${RESET}"
        echo -e "${GREEN} ⏱️ 定时任务状态:${RESET} ${CRON_STATUS}"
        echo -e "${GREEN}----------------------------------${RESET}"
        echo -e "${GREEN}1) 立打包并上传文件/目录${RESET}"
        echo -e "${GREEN}2) 修改 Telegram 配置${RESET}"
        echo -e "${GREEN}3) 清空本地临时缓存文件${RESET}"
        echo -e "${GREEN}4) 定时任务管理${RESET}"
        echo -e "${GREEN}5) 修改备份保留天数${RESET}"
        echo -e "${GREEN}6) 查看已添加的定时备份目录${RESET}"
        echo -e "${GREEN}7) 修改压缩格式${RESET}"
        echo -e "${GREEN}8) 更新${RESET}"
        echo -e "${GREEN}9) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}==================================${RESET}"
        read -p "$(echo -e ${GREEN}请选择: ${RESET})" choice

        case $choice in
            1) 
                do_upload 
                read -rp "操作已结束，按回车键返回主菜单..." dummy
                ;;
            2) init ;;
            3) 
                rm -rf "$TMP_DIR"/* && echo -e "${YELLOW}已清空临时文件夹${RESET}" 
                read -rp "按回车键返回主菜单..." dummy
                ;;
            4) setup_cron_job ;;
            5) set_keep_days ;;
            6) 
                if [[ -f "$CRON_DIRS_FILE" ]]; then
                    echo -e "${YELLOW}当前定时备份目录: $(cat "$CRON_DIRS_FILE")${RESET}"
                else
                    echo -e "${YELLOW}暂无定时目录${RESET}"
                fi
                read -rp "按回车键返回主菜单..." dummy
                ;;
            7) set_archive_format ;;
            8)
                curl -sSL "$SCRIPT_URL" -o "${SCRIPT_PATH}.next" && \
                mv "${SCRIPT_PATH}.next" "$SCRIPT_PATH" && \
                chmod +x "$SCRIPT_PATH"
                echo -e "${GREEN}更新完成！${RESET}" 
                read -rp "按回车键返回主菜单..." dummy
                ;;
            9)
                crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
                rm -rf "$BASE_DIR"
                echo -e "${RED}已完全卸载并清理配置${RESET}"
                exit 0 ;;
            0) exit 0 ;;
            *) 
                echo -e "${RED}无效选项，请重新输入${RESET}" 
                sleep 1
                ;;
        esac
        echo ""
    done
}

# ================== 执行入口 ==================
check_dependencies

if [[ "$1" == "auto_upload" ]]; then
    auto_upload "$2"
else
    # 🌟 核心修复点：判断本地文件不存在，或者本地文件大小为 0（空文件）
    if [[ ! -f "$SCRIPT_PATH" || ! -s "$SCRIPT_PATH" ]]; then
        
        # 放弃不安全的 cp "$0"，无论用户是怎么运行的，一律强制从远程下载保底
        curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
        
        # 如果下载下来还是空的（多发生于 Alpine 缺少证书），给出强提示
        if [[ ! -s "$SCRIPT_PATH" ]]; then
            echo -e "${RED}[错误] 安装失败！本地文件仍为空。${RESET}"
            echo -e "${YELLOW}这通常是因为你的 Alpine 缺少 SSL 证书导致无法连接 GitHub。${RESET}"
            echo -e "${GREEN}请先在终端运行: apk update && apk add ca-certificates curl${RESET}"
            exit 1
        fi
        chmod +x "$SCRIPT_PATH"
    fi
    menu
fi
