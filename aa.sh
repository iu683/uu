#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 全局变量 ==================
BASE_DIR="/opt/docker_backups"
SCRIPT_DIR="$BASE_DIR/scripts"
BACKUP_DIR="$BASE_DIR/data"
CONFIG_FILE="$BASE_DIR/config.sh"
LOG_FILE="$BASE_DIR/cron.log"
REMOTE_SCRIPT_PATH="$SCRIPT_DIR/remote_script.sh"
SSH_KEY="$HOME/.ssh/id_rsa_vpsbackup"
INSTALL_PATH="$(realpath "$0")"
CRON_TAG="#docker_backup_cron"

# 默认配置
RETAIN_DAYS_DEFAULT=7
TG_TOKEN_DEFAULT=""
TG_CHAT_ID_DEFAULT=""
SERVER_NAME_DEFAULT="$(hostname)"
REMOTE_USER_DEFAULT=""
REMOTE_IP_DEFAULT=""
REMOTE_DIR_DEFAULT="$BACKUP_DIR"

mkdir -p "$SCRIPT_DIR" "$BACKUP_DIR"

# ================== 首次运行下载远程脚本 ==================
if [[ ! -f "$REMOTE_SCRIPT_PATH" ]]; then
    echo -e "${CYAN}📥 首次运行，下载远程脚本...${RESET}"
    curl -fsSL "https://raw.githubusercontent.com/iu683/uu/main/aa.sh" -o "$REMOTE_SCRIPT_PATH"
    chmod +x "$REMOTE_SCRIPT_PATH"
    echo -e "${GREEN}✅ 远程脚本已下载到 $REMOTE_SCRIPT_PATH${RESET}"
    exec "$REMOTE_SCRIPT_PATH"
fi

# ================== 配置加载/保存 ==================
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    BACKUP_DIR=${BACKUP_DIR:-$BACKUP_DIR}
    RETAIN_DAYS=${RETAIN_DAYS:-$RETAIN_DAYS_DEFAULT}
    TG_TOKEN=${TG_TOKEN:-$TG_TOKEN_DEFAULT}
    TG_CHAT_ID=${TG_CHAT_ID:-$TG_CHAT_ID_DEFAULT}
    SERVER_NAME=${SERVER_NAME:-$SERVER_NAME_DEFAULT}
    REMOTE_USER=${REMOTE_USER:-$REMOTE_USER_DEFAULT}
    REMOTE_IP=${REMOTE_IP:-$REMOTE_IP_DEFAULT}
    REMOTE_DIR=${REMOTE_DIR:-$REMOTE_DIR_DEFAULT}
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat >"$CONFIG_FILE" <<EOF
BACKUP_DIR="$BACKUP_DIR"
RETAIN_DAYS="$RETAIN_DAYS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
REMOTE_USER="$REMOTE_USER"
REMOTE_IP="$REMOTE_IP"
REMOTE_DIR="$REMOTE_DIR"
EOF
    echo -e "${GREEN}✅ 配置已保存到 $CONFIG_FILE${RESET}"
}

load_config

# ================== Telegram通知 ==================
tg_send() {
    local MESSAGE="$1"
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    local SERVER=${SERVER_NAME:-localhost}
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=[$SERVER] $MESSAGE" >/dev/null 2>&1
}

# ================== SSH密钥自动生成 ==================
setup_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        echo -e "${CYAN}🔑 生成 SSH 密钥...${RESET}"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N ""
        echo -e "${GREEN}✅ 密钥生成完成: $SSH_KEY${RESET}"
        read -rp "请输入远程用户名@IP (例如 root@1.2.3.4): " REMOTE
        ssh-copy-id -i "$SSH_KEY.pub" -o StrictHostKeyChecking=no "$REMOTE"
        echo -e "${GREEN}✅ 密钥已部署到远程: $REMOTE${RESET}"
    fi
}

# ================== 本地备份 ==================
backup_local() {
    read -rp "请输入要备份的 Docker Compose 项目目录（空格分隔）: " -a PROJECT_DIRS
    [[ ${#PROJECT_DIRS[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有输入目录${RESET}"; return; }

    mkdir -p "$BACKUP_DIR"
    for PROJECT_DIR in "${PROJECT_DIRS[@]}"; do
        [[ ! -d "$PROJECT_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"; continue; }

        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}⏸️ 暂停容器: $PROJECT_DIR${RESET}"
            cd "$PROJECT_DIR" || continue
            docker compose down
        fi

        TIMESTAMP=$(date +%F_%H-%M-%S)
        BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup_$TIMESTAMP.tar.gz"
        echo -e "${CYAN}📦 正在备份 $PROJECT_DIR → $BACKUP_FILE${RESET}"
        tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" .

        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器: $PROJECT_DIR${RESET}"
            cd "$PROJECT_DIR" || continue
            docker compose up -d
        fi

        echo -e "${GREEN}✅ 本地备份完成: $BACKUP_FILE${RESET}"
        tg_send "本地备份完成: $(basename "$PROJECT_DIR")"
    done

    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -exec rm -f {} \;
    tg_send "🗑️ 已清理 $RETAIN_DAYS 天以上旧备份"
}


# ================== 远程上传（上传目录内所有备份文件，不解压） ==================
backup_remote_all() {
    [[ ! -d "$BACKUP_DIR" ]] && { echo -e "${RED}❌ 本地备份目录不存在: $BACKUP_DIR${RESET}"; return; }

    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有备份文件${RESET}"; return; }

    echo -e "${CYAN}📤 上传所有备份文件到远程: $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR${RESET}"

    # 远程删除旧备份
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" \
        "mkdir -p \"$REMOTE_DIR\" && rm -f \"$REMOTE_DIR\"/*.tar.gz"

    # 上传所有文件
    for FILE in "${FILE_LIST[@]}"; do
        scp -i "$SSH_KEY" "$FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/" >> "$LOG_FILE" 2>&1
        tg_send "备份上传完成: $(basename "$FILE") → $REMOTE_IP"
    done

    echo -e "${GREEN}✅ 所有备份文件上传完成${RESET}"
}





# ================== 恢复 ==================
restore() {
    read -rp "请输入备份存放目录（默认 $BACKUP_DIR）: " INPUT_DIR
    BACKUP_DIR=${INPUT_DIR:-$BACKUP_DIR}

    [[ ! -d "$BACKUP_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $BACKUP_DIR${RESET}"; return; }
    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有找到任何备份文件${RESET}"; return; }

    echo -e "${CYAN}📂 本地备份文件列表:${RESET}"
    for i in "${!FILE_LIST[@]}"; do
        echo -e "${GREEN}$((i+1)). $(basename "${FILE_LIST[$i]}")${RESET}"
    done

    read -rp "请输入要恢复的序号（空格分隔，all 全选，latest 最新备份）: " SELECTION
    BACKUP_FILES=()
    if [[ "$SELECTION" == "all" ]]; then
        BACKUP_FILES=("${FILE_LIST[@]}")
    elif [[ "$SELECTION" == "latest" ]]; then
        BACKUP_FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz | head -n1))
    else
        for num in $SELECTION; do
            [[ $num =~ ^[0-9]+$ ]] && (( num>=1 && num<=${#FILE_LIST[@]} )) && BACKUP_FILES+=("${FILE_LIST[$((num-1))]}") || echo -e "${RED}❌ 无效序号: $num${RESET}"
        done
    fi
    [[ ${#BACKUP_FILES[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有选择有效文件${RESET}"; return; }

    read -rp "请输入恢复到的项目目录（默认 /opt/原项目名）: " PROJECT_DIR_INPUT
    for FILE in "${BACKUP_FILES[@]}"; do
        BASE_NAME=$(basename "$FILE" | sed 's/_backup_.*\.tar\.gz//')
        TARGET_DIR=${PROJECT_DIR_INPUT:-/opt/$BASE_NAME}
        mkdir -p "$TARGET_DIR"

        echo -e "${CYAN}📂 解压备份 $(basename "$FILE") → $TARGET_DIR${RESET}"
        tar xzf "$FILE" -C "$TARGET_DIR"

        if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器...${RESET}"
            cd "$TARGET_DIR" || continue
            docker compose up -d
            echo -e "${GREEN}✅ 恢复完成: $TARGET_DIR${RESET}"
            tg_send "恢复完成: $BASE_NAME → $TARGET_DIR"
        else
            echo -e "${RED}❌ docker-compose.yml 不存在，无法启动容器${RESET}"
        fi
    done
}

# ================== 配置菜单 ==================
configure_settings_menu() {
    load_config
    while true; do
        clear
        echo -e "${GREEN}=== 配置设置 ===${RESET}"
        echo -e "${GREEN}1. Telegram Bot Token (当前: $TG_TOKEN)${RESET}"
        echo -e "${GREEN}2. Telegram Chat ID (当前: $TG_CHAT_ID)${RESET}"
        echo -e "${GREEN}3. 服务器名称 (当前: $SERVER_NAME)${RESET}"
        echo -e "${GREEN}4. 本地备份保留天数 (当前: $RETAIN_DAYS)${RESET}"
        echo -e "${GREEN}5. 本地备份目录 (当前: $BACKUP_DIR)${RESET}"
        echo -e "${GREEN}6. 远程服务器用户名 (当前: $REMOTE_USER)${RESET}"
        echo -e "${GREEN}7. 远程服务器 IP (当前: $REMOTE_IP)${RESET}"
        echo -e "${GREEN}8. 远程备份目录 (当前: $REMOTE_DIR)${RESET}"
        echo -e "${GREEN}9. 自动备份目录列表 (当前: $BACKUP_DIRS)${RESET}"
        echo -e "${GREEN}0. 返回上级菜单${RESET}"

        read -rp "请选择操作: " choice
        case $choice in
            1) read -rp "请输入 Telegram Bot Token: " input; [[ -n "$input" ]] && TG_TOKEN="$input" ;;
            2) read -rp "请输入 Telegram Chat ID: " input; [[ -n "$input" ]] && TG_CHAT_ID="$input" ;;
            3) read -rp "请输入服务器名称: " input; [[ -n "$input" ]] && SERVER_NAME="$input" ;;
            4) read -rp "请输入本地备份保留天数: " input; [[ -n "$input" ]] && RETAIN_DAYS="$input" ;;
            5) read -rp "请输入本地备份目录: " input; [[ -n "$input" ]] && BACKUP_DIR="$input" ;;
            6) read -rp "请输入远程服务器用户名: " input; [[ -n "$input" ]] && REMOTE_USER="$input" ;;
            7) read -rp "请输入远程服务器 IP: " input; [[ -n "$input" ]] && REMOTE_IP="$input" ;;
            8) read -rp "请输入远程备份目录: " input; [[ -n "$input" ]] && REMOTE_DIR="$input" ;;
            9) read -rp "请输入要自动备份的目录列表（空格分隔）: " input; [[ -n "$input" ]] && BACKUP_DIRS="$input" ;;
            0) save_config; load_config; break ;;
            *) echo -e "${RED}❌ 无效选择${RESET}" ;;
        esac
        save_config
        load_config
        read -rp "按回车继续..."
    done
}

# ================== 定时任务管理 ==================
list_cron() {
    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
    [ ${#lines[@]} -eq 0 ] && { echo -e "${YELLOW}暂无定时任务${RESET}"; return; }
    for i in "${!lines[@]}"; do
        cron=$(echo "${lines[$i]}" | sed "s|$INSTALL_PATH auto||;s|$CRON_TAG||")
        echo "$i) $cron"
    done
}

schedule_add() {
    echo -e "${GREEN}1. 每天0点${RESET}"
    echo -e "${GREEN}2. 每周一0点${RESET}"
    echo -e "${GREEN}3. 每月1号0点${RESET}"
    echo -e "${GREEN}4. 自定义cron${RESET}"
    read -p "选择: " t
    case $t in
        1) cron_expr="0 0 * * *" ;;
        2) cron_expr="0 0 * * 1" ;;
        3) cron_expr="0 0 1 * *" ;;
        4) read -p "请输入自定义 cron 表达式: " cron_expr ;;
        *) echo -e "${RED}❌ 无效选择${RESET}"; return ;;
    esac

    read -p "备份目录(空格分隔, 留空使用默认 $BACKUP_DIR): " dirs
    [[ -z "$dirs" ]] && dirs="$BACKUP_DIR"

    (crontab -l 2>/dev/null; \
    echo "$cron_expr /bin/bash \"$INSTALL_PATH\" auto \"$dirs\" >> \"$LOG_FILE\" 2>&1 $CRON_TAG") | crontab -
    echo -e "${GREEN}✅ 添加成功，cron 日志: $LOG_FILE${RESET}"
}

schedule_del_one() {
    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
    [ ${#lines[@]} -eq 0 ] && { echo -e "${YELLOW}暂无定时任务${RESET}"; return; }
    list_cron
    read -p "输入要删除的编号: " idx
    unset 'lines[idx]'
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; for l in "${lines[@]}"; do echo "$l"; done) | crontab -
    echo -e "${GREEN}✅ 已删除${RESET}"
}

schedule_del_all() {
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}✅ 已清空全部定时任务${RESET}"
}

schedule_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 定时任务管理 ===${RESET}"
        echo -e "${GREEN}------------------------${RESET}"
        list_cron
        echo -e "${GREEN}------------------------${RESET}"
        echo -e "${GREEN}1. 添加任务${RESET}"
        echo -e "${GREEN}2. 删除任务${RESET}"
        echo -e "${GREEN}3. 清空全部${RESET}"
        echo -e "${GREEN}0. 返回${RESET}"
        read -p "选择: " c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
            *) echo -e "${RED}❌ 无效选择${RESET}" ;;
        esac
        read -p "按回车继续..."
    done
}

# ================== 卸载 ==================
uninstall() {
    echo -e "${YELLOW}正在彻底卸载...${RESET}"
    [[ -f "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE" && echo -e "${GREEN}✅ 配置文件已删除${RESET}"
    [[ -f "$REMOTE_SCRIPT_PATH" ]] && rm -f "$REMOTE_SCRIPT_PATH" && echo -e "${GREEN}✅ 远程脚本已删除${RESET}"
    crontab -l 2>/dev/null | grep -v -E "($INSTALL_PATH|$CRON_TAG)" | crontab -
    [[ -d "$BASE_DIR" ]] && rm -rf "$BASE_DIR" && echo -e "${GREEN}✅ 本地备份目录已删除: $BASE_DIR${RESET}"
    [[ -f "$SSH_KEY" ]] && rm -f "$SSH_KEY" "$SSH_KEY.pub" && echo -e "${GREEN}✅ SSH 密钥已删除: $SSH_KEY${RESET}"
    echo -e "${GREEN}✅ 卸载完成，所有文件和定时任务已清理干净${RESET}"
    exit 0
}

# ================== auto模式 ==================
if [[ "$1" == "auto" ]]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root
    load_config
    mkdir -p "$BACKUP_DIR"

    for PROJECT_DIR in $BACKUP_DIRS; do
        [[ ! -d "$PROJECT_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"; continue; }

        # 使用固定文件名覆盖旧备份
        BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup.tar.gz"
        echo -e "${CYAN}📦 自动备份 $PROJECT_DIR → $BACKUP_FILE${RESET}"
        tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" . >> "$LOG_FILE" 2>&1
        tg_send "自动备份完成: $(basename "$PROJECT_DIR") → $BACKUP_FILE"
    done

    # 清理过期备份（可选，如果只保留最新可以注释掉）
    # find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -exec rm -f {} \;
    # tg_send "🗑️ 自动清理 $RETAIN_DAYS 天以上旧备份"

    # 上传远程（覆盖旧备份）
    [[ -n "$REMOTE_USER" && -n "$REMOTE_IP" ]] && backup_remote_all

    exit 0
fi

# ================== 主菜单 ==================
while true; do
    load_config
    clear
    echo -e "${CYAN}=== Docker 备份管理 ===${RESET}"
    echo -e "${GREEN}1. 设置 SSH 密钥自动登录${RESET}"
    echo -e "${GREEN}2. 本地备份${RESET}"
    echo -e "${GREEN}3. 远程上传备份${RESET}"
    echo -e "${GREEN}4. 恢复项目${RESET}"
    echo -e "${GREEN}5. 配置设置（Telegram/服务器名/保留天数/目录/远程信息）${RESET}"
    echo -e "${GREEN}6. 定时任务管理${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择操作: ${RESET})" CHOICE
    case $CHOICE in
        1) setup_ssh_key ;;
        2) backup_local ;;
        3) backup_remote_all ;;
        4) restore ;;
        5) configure_settings_menu ;;
        6) schedule_menu ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
done 修改这个脚本 
