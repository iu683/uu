#!/bin/bash
# ========================================
# Docker 项目自动更新管理器 Pro Max（整合版）
# 功能：
#   ✅ 定时任务调用统一脚本 /usr/local/bin/docker-update.sh
#   ✅ 日志记录 /var/log/docker-update.log
#   ✅ Telegram 成功/失败通知
#   ✅ 手动更新、一键更新、自定义文件夹更新
#   ✅ 删除普通项目和自定义文件夹定时任务
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

PROJECTS_DIR="/opt"
CONF_FILE="/etc/docker-update.conf"
CRON_TAG="# docker-project-update"
UPDATE_SCRIPT="/usr/local/bin/docker-update.sh"


# ========================================
# 初始化配置
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


# ========================================
# 读取配置
# ========================================
load_conf() {
    source "$CONF_FILE"
    [ -z "$SERVER_NAME" ] && SERVER_NAME=$(hostname)
}


# ========================================
# TG 发送（手动更新或一键更新时使用）
# ========================================
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


# ========================================
# 扫描项目
# ========================================
scan_projects() {
    mapfile -t PROJECTS < <(
        find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name docker-compose.yml \
        -exec dirname {} \; | sort
    )
}


# ========================================
# 选择项目
# ========================================
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


# ========================================
# 时间选择（每日/每周/自定义）
# ========================================
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
# 添加项目定时更新
# ========================================
add_update() {
    choose_project || return
    choose_time

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP $UPDATE_SCRIPT $PROJECT_DIR $PROJECT_NAME $CRON_TAG-$PROJECT_NAME") | crontab -

    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 定时更新 ($CRON_EXP)${RESET}"
    read
}


# ========================================
# 删除项目定时更新
# ========================================
remove_update() {
    choose_project || return
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -
    echo -e "${RED}已删除 $PROJECT_NAME 定时更新${RESET}"
    read
}


# ========================================
# 查看所有定时任务
# ========================================
list_update() {
    echo
    crontab -l | grep "$CRON_TAG"
    echo
    read
}


# ========================================
# 手动更新单个项目
# ========================================
run_now() {
    choose_project || return
    load_conf
    $UPDATE_SCRIPT "$PROJECT_DIR" "$PROJECT_NAME"
    read -p "回车继续..."
}


# ========================================
# 一键更新全部项目
# ========================================
update_all() {
    scan_projects
    load_conf

    for dir in "${PROJECTS[@]}"; do
        name=$(basename "$dir")
        $UPDATE_SCRIPT "$dir" "$name"
    done
    read -p "回车继续..."
}


# ========================================
# 自定义文件夹手动更新
# ========================================
custom_folder_update() {
    read -p "请输入要更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ 未找到 docker-compose.yml${RESET}"; read; return; }

    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    load_conf
    $UPDATE_SCRIPT "$CUSTOM_DIR" "$PROJECT_NAME"
    read -p "回车继续..."
}


# ========================================
# 自定义文件夹定时更新
# ========================================
add_custom_update() {
    read -p "请输入要添加定时更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ 未找到 docker-compose.yml${RESET}"; read; return; }

    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    choose_time

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP $UPDATE_SCRIPT $CUSTOM_DIR $PROJECT_NAME $CRON_TAG-$PROJECT_NAME") | crontab -

    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 自定义文件夹定时更新 ($CRON_EXP)${RESET}"
    read
}


# ========================================
# 删除自定义文件夹定时更新
# ========================================
remove_custom_update() {
    read -p "请输入要删除定时更新的文件夹路径: " CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }

    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -

    echo -e "${RED}已删除 $PROJECT_NAME 自定义文件夹定时更新${RESET}"
    read
}


# ========================================
# Telegram 设置
# ========================================
set_tg() {
    read -p "BOT_TOKEN: " token
    read -p "CHAT_ID: " chat
    read -p "服务器名称(自定义，如 HK-01，可留空用hostname): " server

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
# 主菜单
# ========================================
init_conf

while true; do
    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      Docker 项目自动更新管理器      ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1) 添加项目自动更新 (每日/每周/自定义)${RESET}"
    echo -e "${GREEN}2) 删除项目更新任务${RESET}"
    echo -e "${GREEN}3) 查看所有更新规则${RESET}"
    echo -e "${GREEN}4) 立即更新单个项目${RESET}"
    echo -e "${GREEN}5) 设置 Telegram & 服务器名称(可选)${RESET}"
    echo -e "${GREEN}6) ⭐ 一键更新全部项目${RESET}"
    echo -e "${GREEN}7) 自定义文件夹手动更新${RESET}"
    echo -e "${GREEN}8) 自定义文件夹定时更新${RESET}"
    echo -e "${GREEN}9) 删除自定义文件夹定时更新${RESET}"
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
        0) exit ;;
    esac
done
