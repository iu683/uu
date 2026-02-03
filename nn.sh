#!/bin/bash
# ========================================
# Docker 项目自动更新管理器 Pro Max
# 新增：
#   ✅ 一键更新全部项目
#   ✅ 自定义 cron 表达式
# ========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

PROJECTS_DIR="/opt"
CONF_FILE="/etc/docker-update.conf"
CRON_TAG="# docker-project-update"


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
# TG 发送
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
# 时间选择（新增自定义）
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
# 添加更新
# ========================================
add_update() {

    choose_project || return
    choose_time

    CMD="cd $PROJECT_DIR && \
running=\$(docker compose ps -q) && \
[ \"\$running\" != \"\" ] && \
(docker compose pull && docker compose up -d && STATUS=success) || STATUS=fail; \
SERVER=\${SERVER_NAME:-\$(hostname)}; \
MSG=\"🚀 <b>Docker 自动更新</b>%0A服务器: \$SERVER%0A项目: $PROJECT_NAME%0A时间: \$(date '+%F %T')%0A状态: \"; \
[ \$STATUS = success ] && \
curl -s https://api.telegram.org/bot\$BOT_TOKEN/sendMessage -d chat_id=\$CHAT_ID -d text=\"\${MSG}✅ 成功\" >/dev/null || \
curl -s https://api.telegram.org/bot\$BOT_TOKEN/sendMessage -d chat_id=\$CHAT_ID -d text=\"\${MSG}❌ 失败\" >/dev/null"

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP source $CONF_FILE && $CMD $CRON_TAG-$PROJECT_NAME") | crontab -

    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 定时更新 ($CRON_EXP)${RESET}"
    read
}


# ========================================
# 删除更新
# ========================================
remove_update() {

    choose_project || return

    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -

    echo -e "${RED}已删除 $PROJECT_NAME 更新任务${RESET}"
    read
}


# ========================================
# 查看规则
# ========================================
list_update() {
    echo
    crontab -l | grep "$CRON_TAG"
    echo
    read
}


# ========================================
# 立即更新单项目
# ========================================
run_now() {

    choose_project || return
    load_conf

    cd "$PROJECT_DIR"

    if docker compose pull && docker compose up -d; then
        echo -e "${GREEN}✅ 更新成功${RESET}"
        tg_send "🚀 <b>手动更新成功</b>%0A服务器: $SERVER_NAME%0A项目: $PROJECT_NAME"
    else
        echo -e "${RED}❌ 更新失败${RESET}"
        tg_send "❌ <b>手动更新失败</b>%0A服务器: $SERVER_NAME%0A项目: $PROJECT_NAME"
    fi

    read
}


# ========================================
# ⭐ 一键更新全部项目（新增）
# ========================================
update_all() {

    scan_projects
    load_conf

    for dir in "${PROJECTS[@]}"; do
        name=$(basename "$dir")
        cd "$dir"

        if docker compose pull && docker compose up -d; then
            tg_send "🚀 <b>全部更新成功</b>%0A服务器: $SERVER_NAME%0A项目: $name"
            echo -e "${GREEN}✅ $name 更新成功${RESET}"
        else
            tg_send "❌ <b>全部更新失败</b>%0A服务器: $SERVER_NAME%0A项目: $name"
            echo -e "${RED}❌ $name 更新失败${RESET}"
        fi
    done

    read -p "回车继续..."
}


# ========================================
# Telegram 设置
# ========================================
set_tg() {

    read -p "BOT_TOKEN: " token
    read -p "CHAT_ID: " chat
    read -p "服务器名称(可选): " server

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
    echo -e "${GREEN}5) 设置 Telegram & 服务器名称${RESET}"
    echo -e "${GREEN}6) ⭐ 一键更新全部项目${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) add_update ;;
        2) remove_update ;;
        3) list_update ;;
        4) run_now ;;
        5) set_tg ;;
        6) update_all ;;
        0) exit ;;
    esac
done
