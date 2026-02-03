#!/bin/bash
# ========================================
# Docker 项目自动更新管理器
# 支持：
#   ✅ 每日/每周定时更新
#   ✅ 仅更新运行中容器
#   ✅ Telegram 成功/失败通知
#   ✅ 多项目自动识别
#   ✅ 绿色美化菜单
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

PROJECTS_DIR="/opt"
CONF_FILE="/etc/docker-update.conf"
CRON_TAG="# docker-project-update"

# ========================================
# 初始化配置
# ========================================
init_conf() {
    if [ ! -f "$CONF_FILE" ]; then
cat > "$CONF_FILE" <<EOF
BOT_TOKEN=""
CHAT_ID=""
ONLY_RUNNING=true
EOF
    fi
}

# ========================================
# Telegram 通知函数
# ========================================
tg_send() {
    source "$CONF_FILE"

    [ -z "$BOT_TOKEN" ] && return
    [ -z "$CHAT_ID" ] && return

    text="$1"

    curl -s \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$text" \
    -d parse_mode="HTML" >/dev/null 2>&1
}

# ========================================
# 选择项目（⭐ 修复版，不再用 $()）
# ========================================
choose_project() {

    PROJECT_DIR=""

    mapfile -t projects < <(
        find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name "docker-compose.yml" \
        -exec dirname {} \; | sort
    )

    if [ ${#projects[@]} -eq 0 ]; then
        echo -e "${RED}未找到 docker-compose 项目${RESET}"
        echo -e "${YELLOW}目录格式应为: /opt/项目名/docker-compose.yml${RESET}"
        sleep 2
        return
    fi

    clear
    echo -e "${GREEN}=== 请选择要管理的项目 ===${RESET}"

    for i in "${!projects[@]}"; do
        echo -e "${GREEN}$((i+1))) $(basename "${projects[$i]}")${RESET}"
    done
    echo -e "${GREEN}0) 返回${RESET}"

    read -p "$(echo -e ${GREEN}请输入编号:${RESET}) " n

    if [[ "$n" == "0" ]]; then
        return
    fi

    if [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#projects[@]} ]]; then
        PROJECT_DIR="${projects[$((n-1))]}"
    else
        echo -e "${RED}无效选择${RESET}"
        sleep 1
        choose_project
    fi
}

# ========================================
# 选择时间
# ========================================
choose_time() {

    echo
    echo -e "${GREEN}1) 每日更新${RESET}"
    echo -e "${GREEN}2) 每周更新${RESET}"

    read -p "$(echo -e ${GREEN}选择:${RESET}) " mode
    read -p "几点执行(0-23 默认4): " hour
    hour=${hour:-4}

    if [ "$mode" = "1" ]; then
        CRON_EXP="0 $hour * * *"
    else
        echo -e "${GREEN}0=周日 1=周一 ... 6=周六${RESET}"
        read -p "星期(默认0): " week
        week=${week:-0}
        CRON_EXP="0 $hour * * $week"
    fi
}

# ========================================
# 添加更新任务
# ========================================
add_update() {

    choose_project
    [ -z "$PROJECT_DIR" ] && return

    choose_time

    name=$(basename "$PROJECT_DIR")

    CMD="cd $PROJECT_DIR && \
running=\$(docker compose ps -q) && \
[ \"\$running\" != \"\" ] && \
(docker compose pull && docker compose up -d && STATUS=success) || STATUS=fail; \
MSG=\"🚀 <b>Docker 自动更新</b>%0A主机: \$(hostname)%0A项目: $name%0A时间: \$(date '+%F %T')%0A状态: \"; \
[ \$STATUS = success ] && \
curl -s https://api.telegram.org/bot\$BOT_TOKEN/sendMessage -d chat_id=\$CHAT_ID -d text=\"\${MSG}✅ 成功\" >/dev/null || \
curl -s https://api.telegram.org/bot\$BOT_TOKEN/sendMessage -d chat_id=\$CHAT_ID -d text=\"\${MSG}❌ 失败\" >/dev/null"

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$name";
     echo "$CRON_EXP source $CONF_FILE && $CMD $CRON_TAG-$name") | crontab -

    echo -e "${GREEN}✅ 已添加 $name 自动更新 ($CRON_EXP)${RESET}"
    read -p "回车继续..."
}

# ========================================
# 删除任务
# ========================================
remove_update() {

    jobs=$(crontab -l 2>/dev/null | grep "$CRON_TAG")

    [ -z "$jobs" ] && { echo "没有任务"; read; return; }

    echo "$jobs" | nl
    read -p "删除编号: " n

    line=$(echo "$jobs" | sed -n "${n}p")

    crontab -l | grep -vF "$line" | crontab -

    echo -e "${RED}已删除${RESET}"
    read
}

# ========================================
# 查看任务
# ========================================
list_update() {
    echo
    crontab -l | grep "$CRON_TAG"
    echo
    read -p "回车继续..."
}

# ========================================
# 立即更新
# ========================================
run_now() {

    choose_project
    [ -z "$PROJECT_DIR" ] && return

    name=$(basename "$PROJECT_DIR")

    cd "$PROJECT_DIR"

    if docker compose pull && docker compose up -d; then
        echo -e "${GREEN}✅ 更新成功${RESET}"
        tg_send "🚀 <b>手动更新成功</b>%0A项目: $name%0A主机: $(hostname)"
    else
        echo -e "${RED}❌ 更新失败${RESET}"
        tg_send "❌ <b>手动更新失败</b>%0A项目: $name%0A主机: $(hostname)"
    fi

    read -p "回车继续..."
}

# ========================================
# 主菜单（全绿）
# ========================================
init_conf

while true; do
    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      Docker 项目自动更新管理器      ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1) 添加项目自动更新 (每日/每周)${RESET}"
    echo -e "${GREEN}2) 删除项目更新任务${RESET}"
    echo -e "${GREEN}3) 查看所有更新规则${RESET}"
    echo -e "${GREEN}4) 立即手动更新一次${RESET}"
    echo -e "${GREEN}5) 编辑 Telegram 配置${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) add_update ;;
        2) remove_update ;;
        3) list_update ;;
        4) run_now ;;
        5) nano "$CONF_FILE" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
    esac
done
