#!/bin/bash

# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 全局变量 ==================
BASE_DIR="/opt/docker_backups"
CONFIG_FILE="$BASE_DIR/config.sh"
LOG_FILE="$BASE_DIR/cron.log"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
REMOTE_SCRIPT_PATH="$BASE_DIR/remote_script.sh"
SSH_KEY="$BASE_DIR/id_rsa_vpsbackup"

mkdir -p "$BASE_DIR"


# 默认配置
BACKUP_DIR_DEFAULT="$BASE_DIR"
RETAIN_DAYS_DEFAULT=7
TG_TOKEN_DEFAULT=""
TG_CHAT_ID_DEFAULT=""
SERVER_NAME_DEFAULT="$(hostname)"
REMOTE_USER_DEFAULT=""
REMOTE_IP_DEFAULT=""
REMOTE_DIR_DEFAULT="$BASE_DIR"
SSH_KEY="$HOME/.ssh/id_rsa_vpsbackup"

# 首次运行自动下载远程脚本
if [[ ! -f "$REMOTE_SCRIPT_PATH" ]]; then
    echo -e "${CYAN}📥 首次运行，下载远程脚本...${RESET}"
    mkdir -p "$(dirname "$REMOTE_SCRIPT_PATH")"
    curl -fsSL "$SCRIPT_URL" -o "$REMOTE_SCRIPT_PATH"
    chmod +x "$REMOTE_SCRIPT_PATH"
    echo -e "${GREEN}✅ 远程脚本已下载到 $REMOTE_SCRIPT_PATH${RESET}"

    # 自动执行远程脚本，显示菜单
    exec "$REMOTE_SCRIPT_PATH"
fi


# ================== 配置加载/保存 ==================
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    BACKUP_DIR=${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}
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
tg_notify() {
    local MESSAGE="$1"
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && return
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
         -d chat_id="$TG_CHAT_ID" \
         -d text "[$SERVER_NAME] $MESSAGE" >/dev/null 2>&1
}

# ================== SSH密钥自动生成并配置 ==================
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
    read -rp "请输入要备份的 Docker Compose 项目目录（可多选，空格分隔）: " -a PROJECT_DIRS
    [[ ${#PROJECT_DIRS[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有输入目录${RESET}"; return; }

    mkdir -p "$BACKUP_DIR"
    for PROJECT_DIR in "${PROJECT_DIRS[@]}"; do
        [[ ! -d "$PROJECT_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"; continue; }

        # 暂停容器
        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}⏸️ 暂停容器: $PROJECT_DIR${RESET}"
            cd "$PROJECT_DIR" || continue
            docker compose down
        fi

        TIMESTAMP=$(date +%F_%H-%M-%S)
        BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup_$TIMESTAMP.tar.gz"
        echo -e "${CYAN}📦 正在备份 $PROJECT_DIR → $BACKUP_FILE${RESET}"
        tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" .

        # 备份完成，自动启动容器
        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器: $PROJECT_DIR${RESET}"
            cd "$PROJECT_DIR" || continue
            docker compose up -d
        fi

        echo -e "${GREEN}✅ 本地备份完成: $BACKUP_FILE${RESET}"
        tg_notify "本地备份完成: $(basename "$PROJECT_DIR")"
    done

    # 清理旧备份
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +"$RETAIN_DAYS" -exec rm -f {} \;
    echo -e "${YELLOW}🗑️ 已清理超过 $RETAIN_DAYS 天的旧备份${RESET}"
    tg_notify "🗑️ 已清理 $RETAIN_DAYS 天以上旧备份"
}


# ================== 远程上传 ==================
backup_remote() {
    [[ ! -d "$BACKUP_DIR" ]] && { echo -e "${RED}❌ 目录不存在: $BACKUP_DIR${RESET}"; return; }
    FILE_LIST=("$BACKUP_DIR"/*.tar.gz)
    [[ ${#FILE_LIST[@]} -eq 0 ]] && { echo -e "${RED}❌ 没有备份文件${RESET}"; return; }

    mkdir -p "$BASE_DIR/tmp_upload"
    TIMESTAMP=$(date +%F_%H-%M-%S)
    TEMP_PACKAGE="$BASE_DIR/tmp_upload/backup_upload_$(date +%F_%H-%M-%S).tar.gz"

    echo -e "${CYAN}📦 打包所有备份文件...${RESET}"
    tar czf "$TEMP_PACKAGE" -C "$BACKUP_DIR" .

    echo -e "${CYAN}📤 上传到远程 $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR ...${RESET}"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"
    scp -i "$SSH_KEY" "$TEMP_PACKAGE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"

    echo -e "${CYAN}📂 远程解压...${RESET}"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "tar xzf $REMOTE_DIR/$(basename "$TEMP_PACKAGE") -C $REMOTE_DIR && rm -f $REMOTE_DIR/$(basename "$TEMP_PACKAGE")"

    echo -e "${GREEN}✅ 远程上传完成${RESET}"
    tg_notify "远程备份上传完成: $(basename "$TEMP_PACKAGE") 到 $REMOTE_IP"
    rm -f "$TEMP_PACKAGE"
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

    read -rp "请输入要恢复的序号（空格分隔，all 全选）: " SELECTION
    BACKUP_FILES=()
    if [[ "$SELECTION" == "all" ]]; then
        BACKUP_FILES=("${FILE_LIST[@]}")
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
            tg_notify "恢复完成: $BASE_NAME → $TARGET_DIR"
        else
            echo -e "${RED}❌ docker-compose.yml 不存在，无法启动容器${RESET}"
        fi
    done
}

# ================== 定时任务管理 ==================
list_cron(){
    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
    [ ${#lines[@]} -eq 0 ] && { echo -e "${YELLOW}暂无定时任务${RESET}"; return; }
    for i in "${!lines[@]}"; do
        cron=$(echo "${lines[$i]}" | sed "s|$INSTALL_PATH auto $CRON_TAG||")
        echo "$i) $cron"
    done
}

schedule_add(){
    echo -e "${GREEN}1 每天0点${RESET}"
    echo -e "${GREEN}2 每周一0点${RESET}"
    echo -e "${GREEN}3 每月1号${RESET}"
    echo -e "${GREEN}4 自定义cron${RESET}"
    read -p "选择: " t
    case $t in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "cron表达式: " cron ;;
        *) return ;;
    esac

    read -p "备份目录(空格分隔, 留空使用默认): " dirs
    if [ -n "$dirs" ]; then
        (crontab -l 2>/dev/null; \
         echo "$cron /bin/bash $INSTALL_PATH auto \"$dirs\" >> $LOG_FILE 2>&1 $CRON_TAG") | crontab -
    else
        (crontab -l 2>/dev/null; \
         echo "$cron /bin/bash $INSTALL_PATH auto >> $LOG_FILE 2>&1 $CRON_TAG") | crontab -
    fi

    echo -e "${GREEN}✅ 添加成功，cron日志: $LOG_FILE${RESET}"
}


schedule_del_one(){
    mapfile -t lines < <(crontab -l 2>/dev/null | grep "$CRON_TAG")
    [ ${#lines[@]} -eq 0 ] && return
    list_cron
    read -p "输入编号: " idx
    unset 'lines[idx]'
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; for l in "${lines[@]}"; do echo "$l"; done) | crontab
    echo -e "${GREEN}✅ 已删除${RESET}"
}

schedule_del_all(){
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}✅ 已清空全部定时任务${RESET}"
}

schedule_menu(){
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
        read -p "$(echo -e ${GREEN}选择: ${RESET})" c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

# ================== 配置设置 ==================
configure_settings() {
    read -rp "本地备份目录（当前: $BACKUP_DIR）: " INPUT
    [[ -n "$INPUT" ]] && BACKUP_DIR="$INPUT"

    read -rp "备份保留天数（当前: $RETAIN_DAYS）: " INPUT
    [[ -n "$INPUT" ]] && RETAIN_DAYS="$INPUT"

    read -rp "Telegram Bot Token（当前: $TG_TOKEN）: " INPUT
    [[ -n "$INPUT" ]] && TG_TOKEN="$INPUT"

    read -rp "Telegram Chat ID（当前: $TG_CHAT_ID）: " INPUT
    [[ -n "$INPUT" ]] && TG_CHAT_ID="$INPUT"

    read -rp "服务器名称（当前: $SERVER_NAME）: " INPUT
    [[ -n "$INPUT" ]] && SERVER_NAME="$INPUT"

    read -rp "远程用户名（当前: $REMOTE_USER）: " INPUT
    [[ -n "$INPUT" ]] && REMOTE_USER="$INPUT"

    read -rp "远程 IP（当前: $REMOTE_IP）: " INPUT
    [[ -n "$INPUT" ]] && REMOTE_IP="$INPUT"

    read -rp "远程目录（当前: $REMOTE_DIR）: " INPUT
    [[ -n "$INPUT" ]] && REMOTE_DIR="$INPUT"

    save_config
}

# ================== 卸载 ==================
uninstall() {
    echo -e "${YELLOW}正在自动卸载...${RESET}"

    # 删除配置文件
    [[ -f "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE"

    # 删除远程脚本
    [[ -f "$REMOTE_SCRIPT_PATH" ]] && rm -f "$REMOTE_SCRIPT_PATH"

    # 移除定时任务
    crontab -l | grep -v "$INSTALL_PATH" | crontab -

    echo -e "${GREEN}✅ 卸载完成，配置和脚本已删除，定时任务已移除${RESET}"
    exit 0
}


# ================== 自动执行备份任务 ==================
if [[ "$1" == "auto" ]]; then
    load_config
    backup_local
    [[ -n "$REMOTE_USER" && -n "$REMOTE_IP" ]] && backup_remote
    exit 0
fi

# ================== 菜单 ==================
while true; do
    load_config
    clear
    echo -e "${CYAN}=== Docker 远程备份管理 ===${RESET}"
    echo -e "${GREEN}1. 设置 SSH 密钥自动登录${RESET}"
    echo -e "${GREEN}2. 本地备份${RESET}"
    echo -e "${GREEN}3. 远程上传备份${RESET}"
    echo -e "${GREEN}4. 恢复项目${RESET}"
    echo -e "${GREEN}5. 配置设置（保留天数/TG/服务器名/远程）${RESET}"
    echo -e "${GREEN}6. 定时任务管理${RESET}"
    echo -e "${GREEN}7. 卸载脚本${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -rp "$(echo -e ${GREEN}请选择操作: ${RESET})" CHOICE
    case $CHOICE in
        1) setup_ssh_key ;;
        2) backup_local ;;
        3) backup_remote ;;
        4) restore ;;
        5) configure_settings ;;
        6) schedule_menu ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    read -p "按回车继续..."
done
