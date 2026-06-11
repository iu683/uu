#!/bin/bash
# ========================================
# Docker 自动更新管理器
# 功能：
#   ✅ 运行即安装到 /root/dockerupdate.sh 并赋权限
#   ✅ 定时任务调用固定脚本路径 /root/dockerupdate.sh
#   ✅ 日志 /var/log/docker-update.log
#   ✅ Telegram 成功/失败通知
#   ✅ 手动更新、一键更新、自定义文件夹更新
#   ✅ 添加/删除普通项目和自定义文件夹定时任务
#   ✅ 卸载管理器（删除脚本+定时任务）
# 使用：
#   手动执行管理器: ./dockerupdate.sh
#   定时任务: /root/dockerupdate.sh /项目路径 项目名称
# ========================================

SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/oo.sh"
SCRIPT_PATH="/root/dockerupdate.sh"
CRON_TAG="# docker-project-update"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

PROJECTS_DIR="/opt"
CONF_FILE="/etc/docker-update.conf"
LOG_FILE="/var/log/docker-update.log"

# ========================================
# 自动下载安装管理器
# ========================================
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 安装失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
fi

# ========================================
# 卸载管理器函数
# ========================================
uninstall_manager() {
    echo -e "${RED}正在卸载管理器...${RESET}"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}✅ 已删除所有 Docker 定时任务${RESET}"
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && echo -e "${GREEN}✅ 已删除管理器脚本${RESET}"
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
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

# ========================================
# 定时任务执行逻辑
# ========================================
run_update() {
    PROJECT_DIR="$1"
    PROJECT_NAME="$2"
    load_conf
    SERVER=${SERVER_NAME:-$(hostname)}

    [ ! -d "$PROJECT_DIR" ] && echo "$(date '+%F %T') $PROJECT_NAME 目录不存在" | tee -a "$LOG_FILE" && return
    [ ! -f "$PROJECT_DIR/docker-compose.yml" ] && echo "$(date '+%F %T') $PROJECT_NAME docker-compose.yml 不存在" | tee -a "$LOG_FILE" && return

    cd "$PROJECT_DIR" || return
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

    running=$(docker compose ps -q)
    if [ "$running" != "" ]; then
        echo -e "${GREEN}🚀 开始更新 $PROJECT_NAME ...${RESET}"
        if docker compose pull 2>&1 | tee -a "$LOG_FILE" && docker compose up -d 2>&1 | tee -a "$LOG_FILE"; then
            tg_send "🚀 <b>Docker 自动更新</b>%0A服务器: $SERVER%0A项目: $PROJECT_NAME%0A时间: $(date '+%F %T')%0A状态: ✅ 成功"
            echo "$(date '+%F %T') $PROJECT_NAME 更新成功" | tee -a "$LOG_FILE"
        else
            tg_send "🚀 <b>Docker 自动更新</b>%0A服务器: $SERVER%0A项目: $PROJECT_NAME%0A时间: $(date '+%F %T')%0A状态: ❌ 失败"
            echo "$(date '+%F %T') $PROJECT_NAME 更新失败" | tee -a "$LOG_FILE"
        fi
        echo -e "${GREEN}✅ $PROJECT_NAME 更新完成${RESET}"
    else
        echo "$(date '+%F %T') $PROJECT_NAME 未运行" | tee -a "$LOG_FILE"
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
        read -p "几点执行(默认0): " hour
        hour=${hour:-0}
        CRON_EXP="0 $hour * * *"
    elif [ "$mode" = "2" ]; then
        read -p "几点执行(默认0): " hour
        hour=${hour:-0}
        echo "0=周日 1=周一 ... 6=周六"
        read -p "星期(默认1): " week
        week=${week:-1}
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
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

remove_update() {
    choose_project || return
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -
    echo -e "${RED}已删除 $PROJECT_NAME 定时更新${RESET}"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

list_update() {
    clear
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${GREEN}         📂 当前生效的 Docker 定时更新任务        ${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    
    # 获取属于管理器的 crontab 任务
    cron_items=$(crontab -l 2>/dev/null | grep "$CRON_TAG")
    
    if [ -z "$cron_items" ]; then
        echo -e "${RED}❌ 暂无任何自动更新任务。${RESET}"
    else
        echo -e "${YELLOW} 状态   | 运行周期 (Cron)      | 项目名称 --> 路径${RESET}"
        echo -e "${GREEN}--------------------------------------------------${RESET}"
        
        # 逐行解析并高亮打印
        echo "$cron_items" | while read -r line; do
            # 提取 cron 表达式（前5个字段）
            cron_exp=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
            # 提取项目路径和名称
            p_path=$(echo "$line" | awk '{print $7}')
            p_name=$(echo "$line" | awk '{print $8}')
            
            # 美化输出
            printf " [${GREEN}启用${RESET}]  | %-20s | ${GREEN}%-12s${RESET} --> %s\n" "$cron_exp" "$p_name" "$p_path"
        done
        
        echo -e "${GREEN}--------------------------------------------------${RESET}"
    fi
    
    echo -e "${GREEN}==================================================${RESET}"
    echo
    
    # 顺便展示最后 3 条日志，方便一眼看出最近有没有正常跑
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo -e "${GREEN}📋 最近 3 条更新日志记录：${RESET}"
        tail -n 3 "$LOG_FILE"
        echo
    fi
    
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

# 用于在主菜单内渲染任务看板的函数
show_menu_cron_board() {
    cron_items=$(crontab -l 2>/dev/null | grep "$CRON_TAG")
    echo -e "${YELLOW}📅 [当前生效的定时更新任务]${RESET}"
    if [ -z "$cron_items" ]; then
        echo -e "${RED}   暂无任何定时任务${RESET}"
    else
        echo "$cron_items" | while read -r line; do
            cron_exp=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
            p_name=$(echo "$line" | awk '{print $8}')
            printf "   🔹 %-12s | 周期: %-15s\n" "$p_name" "$cron_exp"
        done
    fi
}

run_now() {
    choose_project || return
    run_update "$PROJECT_DIR" "$PROJECT_NAME"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

update_all() {
    scan_projects
    for dir in "${PROJECTS[@]}"; do
        name=$(basename "$dir")
        run_update "$dir" "$name"
    done
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}


custom_folder_update() {
    read -p "$(echo -e ${GREEN}请输入要更新的文件夹路径: ${RESET})" CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ docker-compose.yml 不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    run_update "$CUSTOM_DIR" "$PROJECT_NAME"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}


add_custom_update() {
    read -p "$(echo -e ${GREEN}请输入要添加定时更新的文件夹路径: ${RESET})" CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    [ ! -f "$CUSTOM_DIR/docker-compose.yml" ] && { echo -e "${RED}❌ docker-compose.yml 不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    choose_time
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME";
     echo "$CRON_EXP $SCRIPT_PATH $CUSTOM_DIR $PROJECT_NAME $CRON_TAG-$PROJECT_NAME") | crontab -
    echo -e "${GREEN}✅ 已添加 $PROJECT_NAME 自定义文件夹定时更新 ($CRON_EXP)${RESET}"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

remove_custom_update() {
    read -p "$(echo -e ${GREEN}请输入要删除定时更新的文件夹路径: ${RESET})" CUSTOM_DIR
    [ ! -d "$CUSTOM_DIR" ] && { echo -e "${RED}❌ 文件夹不存在${RESET}"; read; return; }
    PROJECT_NAME=$(basename "$CUSTOM_DIR")
    crontab -l 2>/dev/null | grep -v "$CRON_TAG-$PROJECT_NAME" | crontab -
    echo -e "${RED}已删除 $PROJECT_NAME 自定义文件夹定时更新${RESET}"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

delete_log() {
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    echo -e "${RED}✅ 日志已删除${RESET}"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

add_all_updates() {
    scan_projects
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        echo -e "${RED}未找到 docker-compose 项目${RESET}"
        read
        return
    fi

    echo -e "${GREEN}=== 扫描到项目列表 ===${RESET}"
    for dir in "${PROJECTS[@]}"; do
        echo "- $(basename "$dir")"
    done

    choose_time  # 统一选择 cron 时间

    for dir in "${PROJECTS[@]}"; do
        name=$(basename "$dir")
        # 添加到 crontab
        (crontab -l 2>/dev/null | grep -v "$CRON_TAG-$name";
         echo "$CRON_EXP $SCRIPT_PATH $dir $name $CRON_TAG-$name") | crontab -
        echo -e "${GREEN}✅ 已添加 $name 定时更新 ($CRON_EXP)${RESET}"
    done
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

remove_all_updates() {
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${RED}✅ 已删除所有 Docker 定时任务${RESET}"
    read -p "$(echo -e ${GREEN}回车继续...${RESET})"
}

# ========================================
# 管理器自更新（极简覆盖版）
# ========================================
self_update() {
    load_conf
    SERVER=${SERVER_NAME:-$(hostname)}

    echo -e "${GREEN}🚀 正在更新管理器...${RESET}"

    TMP=$(mktemp)

    if ! curl -fsSL "$SCRIPT_URL" -o "$TMP"; then
        echo -e "${RED}❌ 下载失败${RESET}"
        return
    fi

    chmod +x "$TMP"
    mv -f "$TMP" "$SCRIPT_PATH"

    tg_send "🚀 <b>Docker 管理器已更新</b>%0A服务器: $SERVER%0A时间: $(date '+%F %T')"

    echo -e "${GREEN}✅ 更新完成，重新启动...${RESET}"

    exec "$SCRIPT_PATH"
}

# ========================================
# 主菜单
# ========================================
init_conf
while true; do
    clear
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}  ◈    Docker 自动更新管理器    ◈   ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    show_menu_cron_board
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1) 添加项目自动更新${RESET}"
    echo -e "${GREEN} 2) 删除项目更新任务${RESET}"
    echo -e "${GREEN} 3) 查看所有更新任务${RESET}"
    echo -e "${GREEN} 4) 立即更新单个项目${RESET}"
    echo -e "${GREEN} 5) 设置 Telegram & 服务器名称(可选)${RESET}"
    echo -e "${GREEN} 6) 一键更新全部项目${RESET}"
    echo -e "${GREEN} 7) 自定义文件夹手动更新${RESET}"
    echo -e "${GREEN} 8) 自定义文件夹定时更新${RESET}"
    echo -e "${GREEN} 9) 删除自定义文件夹定时更新${RESET}"
    echo -e "${GREEN}10) 全部添加定时任务${RESET}"
    echo -e "${GREEN}11) 全部删除定时任务${RESET}"
    echo -e "${GREEN}12) 删除日志文件${RESET}"
    echo -e "${GREEN}13) 更新管理器${RESET}"
    echo -e "${GREEN}14) 卸载管理器${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}====================================${RESET}"

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
        10) add_all_updates ;;
        11) remove_all_updates ;;
        12) delete_log ;;
        13) self_update ;;
        14) uninstall_manager ;;
    
        0) exit 0 ;;
    esac
done
