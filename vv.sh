#!/bin/bash
# ========================================
# Docker 自动更新管理器 Pro Max（单文件整合版）
# 功能：
#   ✅ 运行即安装到 /root/docker-manager.sh 并赋权限
#   ✅ 定时任务调用固定脚本路径 /root/docker-manager.sh
#   ✅ 日志 /var/log/docker-update.log
#   ✅ Telegram 成功/失败通知
#   ✅ 手动更新、一键更新、自定义文件夹更新
#   ✅ 添加/删除普通项目和自定义文件夹定时任务
#   ✅ 卸载管理器（删除脚本+定时任务）
# 使用：
#   手动执行管理器: ./docker-manager.sh
#   定时任务: /root/docker-manager.sh /项目路径 项目名称
# ========================================

SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/vv.sh"
SCRIPT_PATH="/root/docker-manager.sh"
CRON_TAG="# docker-project-update"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

PROJECTS_DIR="/opt"
CONF_FILE="/etc/docker-update.conf"
LOG_FILE="/var/log/docker-update.log"

# ========================================
# 自动下载安装管理器
# ========================================
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}🚀 管理器不存在，正在下载到 $SCRIPT_PATH ...${RESET}"
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 下载完成，脚本已赋权限${RESET}"
fi

# ========================================
# 卸载管理器函数
# ========================================
uninstall_manager() {
    echo -e "${RED}⚠️ 正在卸载管理器...${RESET}"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}✅ 已删除所有 Docker 定时任务${RESET}"
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && echo -e "${GREEN}✅ 已删除管理器脚本 $SCRIPT_PATH${RESET}"
    echo -e "${GREEN}卸载完成${RESET}"
    exit 0
}

# ========================================
# 配置与 Telegram 功能
# ========================================
init_conf() {
    [ -f "$CONF_FILE" ] && return
cat > "$CONF_FILE" <<EOF
BOT_TOKEN=""
CHAT_ID=""
SERVER_NAME=""
ONLY_RUNNING=true
EOF
}

load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    [ -z "$SERVER_NAME" ] && SERVER_NAME=$(hostname)
}

tg_send() {
    load_conf
    [ -z "$BOT_TOKEN" ] && return
    [ -z "$CHAT_ID" ] && return
    curl -s \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$1" \
        -d parse_mode="HTML" >/dev/null 2>&1
}

set_tg() {
    read -p "BOT_TOKEN: " token
    read -p "CHAT_ID: " chat
    read -p "服务器名称(可留空用hostname): " server
cat > "$CONF_FILE" <<EOF
BOT_TOKEN="$token"
CHAT_ID="$chat"
SERVER_NAME="$server"
ONLY_RUNNING=true
EOF
    echo -e "${GREEN}保存成功${RESET}"
    read
}

# ========================================
# 定时任务执行逻辑
# ========================================
run_update() {
    PROJECT_DIR="$1"
    PROJECT_NAME="$2"
    load_conf
    SERVER=${SERVER_NAME:-$(hostname)}

    [ ! -d "$PROJECT_DIR" ] && echo "$(date '+%F %T') $PROJECT_NAME 目录不存在" >> "$LOG_FILE" && return
    [ ! -f "$PROJECT_DIR/docker-compose.yml" ] && echo "$(date '+%F %T') $PROJECT_NAME docker-compose.yml 不存在" >> "$LOG_FILE" && return

    cd "$PROJECT_DIR" || return
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

    running=$(docker compose ps -q)
    if [ "$running" != "" ]; then
        if docker compose pull >> "$LOG_FILE" 2>&1 && docker compose up -d >> "$LOG_FILE" 2>&1; then
            tg_send "🚀 <b>Docker 自动更新</b>%0A服务器: $SERVER%0A项目: $PROJECT_NAME%0A时间: $(date '+%F %T')%0A状态: ✅ 成功"
            echo "$(date '+%F %T') $PROJECT_NAME 更新成功" >> "$LOG_FILE"
        else
            tg_send "🚀 <b>Docker 自动更新</b>%0A服务器: $SERVER%0A项目: $PROJECT_NAME%0A时间: $(date '+%F %T')%0A状态: ❌ 失败"
            echo "$(date '+%F %T') $PROJECT_NAME 更新失败" >> "$LOG_FILE"
        fi
    else
        echo "$(date '+%F %T') $PROJECT_NAME 未运行" >> "$LOG_FILE"
    fi
}

# ========================================
# 定时任务模式
# ========================================
if [ -n "$1" ] && [ -n "$2" ]; then
    run_update "$1" "$2"
    exit 0
fi

# ========================================
# 项目扫描与选择
# ========================================
scan_projects() {
    mapfile -t PROJECTS < <(
        find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name docker-compose.yml \
        -exec dirname {} \; | sort
    )
}

choose_project() {
    scan_projects
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        echo -e "${RED}未找到 docker-compose 项目${RESET}"
        sleep 2
        return 1
    fi
    clear
    echo -e "${GREEN}=== 请选择项目 ===${RESET}"
    for i in "${!PROJECTS[@]}"; do
        echo -e "${GREEN}$((i+1))) $(basename "${PROJECTS[$i]}")${RESET}"
    done
    echo -e "${GREEN}0) 返回${RESET}"
    read -p "$(echo -e ${GREEN}请输入编号:${RESET}) " n
    [[ "$n" == "0" ]] && return 1
    PROJECT_DIR="${PROJECTS[$((n-1))]}"
    PROJECT_NAME=$(basename "$PROJECT_DIR")
}

choose_time() {
    echo
    echo -e "${GREEN}1) 每日更新${RESET}"
    echo -e "${GREEN}2) 每周更新${RESET}"
    echo -e "${GREEN}3) 自定义 cron${RESET}"
    read -p "$(echo -e ${GREEN}选择:${RESET}) " mode
    if [ "$mode" = "1" ]; then
        read -p "几点执行(默认4): " hour
        hour=${hour:-4}
        CRON_EXP="0 $hour * * *"
    elif [ "$mode" = "2" ]; then
        read -p "几点执行(默认4): " hour
        hour=${hour:-4}
        echo "0=周日 1=周一 ... 6=周六"
        read -p "星期(默认0): " week
        week=${week:-0}
        CRON_EXP="0 $hour * * $week"
    else
        echo "示例: */30 * * * *"
        read -p "请输入完整 cron: " CRON_EXP
    fi
}

# ========================================
# 定时任务添加/删除
# ========================================
add_update() {
    choose_project || return
    choose_time
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP $SCRIPT_PATH $PROJECT_DIR $PROJECT_NAME $CRON_TAG-$PROJECT_NAME") | crontab -
    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 定时更新 ($CRON_EXP)${RESET}"
    read
}

remove_update() {
    choose_project || return
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -
    echo -e "${RED}已删除 $PROJECT_NAME 定时更新${RESET}"
    read
}

list_update() {
    echo
    crontab -l | grep "$CRON_TAG"
    echo
    read
}

run_now() {
    choose_project || return
    run_update "$PROJECT_DIR" "$PROJECT_NAME"
    read -p "回车继续..."
}

update_all() {
    scan_projects
    for dir in "${PROJECTS[@]}"; do
        name=$(basename "$dir")
        run_update "$dir" "$name"
    done
    read -p "回车继续..."
}

custom_folder_update() {
    read -p "请输入要更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ docker-compose.yml 不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    run_update "$CUSTOM_DIR" "$PROJECT_NAME"
    read -p "回车继续..."
}

add_custom_update() {
    read -p "请输入要添加定时更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ docker-compose.yml 不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    choose_time
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP $SCRIPT_PATH $CUSTOM_DIR $PROJECT_NAME $CRON_TAG-$PROJECT_NAME") | crontab -
    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 自定义文件夹定时更新 ($CRON_EXP)${RESET}"
    read
}

remove_custom_update() {
    read -p "请输入要删除定时更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -
    echo -e "${RED}已删除 $PROJECT_NAME 自定义文件夹定时更新${RESET}"
    read
}

delete_log() {
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    echo -e "${RED}✅ 日志已删除${RESET}"
    read
}

# ========================================
# 主菜单
# ========================================
init_conf
while true; do
    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      Docker 自动更新管理器      ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1) 添加项目自动更新${RESET}"
    echo -e "${GREEN}2) 删除项目更新任务${RESET}"
    echo -e "${GREEN}3) 查看所有更新任务${RESET}"
    echo -e "${GREEN}4) 立即更新单个项目${RESET}"
    echo -e "${GREEN}5) 设置 Telegram & 服务器名称(可选)${RESET}"
    echo -e "${GREEN}6) 一键更新全部项目${RESET}"
    echo -e "${GREEN}7) 自定义文件夹手动更新${RESET}"
    echo -e "${GREEN}8) 自定义文件夹定时更新${RESET}"
    echo -e "${GREEN}9) 删除自定义文件夹定时更新${RESET}"
    echo -e "${GREEN}10) 卸载管理器${RESET}"
    echo -e "${GREEN}11) 删除日志文件${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice
    case $choice in
        1) add_update ;;
        2) remove_update ;;
        3) list_update ;;
        4) run_now ;;
        5) set_tg ;;
        6) update_all ;;
        7) custom_folder_update ;;
        8) add_custom_update ;;
        9) remove_custom_update ;;
        10) uninstall_manager ;;
        11) delete_log ;;
        0) exit 0 ;;
    esac
done
