#!/bin/bash

# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 默认备份目录
DEFAULT_BACKUP_DIR="/opt/docker_backups"
mkdir -p "$DEFAULT_BACKUP_DIR"

# ================== 获取卷目录函数 ==================
get_volume_dirs() {
    local PROJECT_DIR=$1
    # 查找 docker-compose.yml 中的挂载目录
    VOLUME_DIRS=()
    while read -r line; do
        # 匹配 "volumes: ..." 形式
        if [[ $line =~ ^[[:space:]]*-?[[:space:]]*([./a-zA-Z0-9_-]+): ]]; then
            host_dir=${BASH_REMATCH[1]}
            # 转换成绝对路径
            if [[ ! "$host_dir" =~ ^/ ]]; then
                host_dir="$PROJECT_DIR/$host_dir"
            fi
            [[ -d "$host_dir" ]] && VOLUME_DIRS+=("$host_dir")
        fi
    done < <(grep '^[[:space:]]*-[[:space:]]*.*:.*' "$PROJECT_DIR/docker-compose.yml")
    echo "${VOLUME_DIRS[@]}"
}

# ================== 备份函数 ==================
backup() {
    read -rp "请输入要备份的项目目录（多个空格分隔）: " -a PROJECT_DIRS
    read -rp "请输入备份存放目录（默认 $DEFAULT_BACKUP_DIR）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%F_%H-%M-%S)

    for PROJECT_DIR in "${PROJECT_DIRS[@]}"; do
        if [[ ! -d "$PROJECT_DIR" ]]; then
            echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"
            continue
        fi

        BASENAME=$(basename "$PROJECT_DIR")
        BACKUP_FILE="$BACKUP_DIR/${BASENAME}_backup_$TIMESTAMP.tar.gz"

        echo -e "${CYAN}📦 开始备份项目目录: $PROJECT_DIR → $BACKUP_FILE${RESET}"

        # 获取卷目录
        VOLUME_DIRS=$(get_volume_dirs "$PROJECT_DIR")
        # 生成临时目录放置卷数据和配置
        TMP_DIR=$(mktemp -d)
        cp -r "$PROJECT_DIR/docker-compose.yml" "$TMP_DIR/"

        for vol in $VOLUME_DIRS; do
            vol_name=$(basename "$vol")
            mkdir -p "$TMP_DIR/$vol_name"
            cp -r "$vol/." "$TMP_DIR/$vol_name/"
        done

        tar czf "$BACKUP_FILE" -C "$TMP_DIR" .
        rm -rf "$TMP_DIR"

        echo -e "${GREEN}✅ 已备份 $PROJECT_DIR → $BACKUP_FILE${RESET}"
    done
}

# ================== 恢复函数 ==================
restore() {
    read -rp "请输入备份文件路径（支持多个空格分隔）: " -a BACKUP_FILES

    for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
        if [[ ! -f "$BACKUP_FILE" ]]; then
            echo -e "${RED}❌ 备份文件不存在: $BACKUP_FILE${RESET}"
            continue
        fi

        # 自动获取原项目目录名
        BASENAME=$(basename "$BACKUP_FILE")
        PROJECT_DIR_NAME="${BASENAME%%_backup_*}"
        PROJECT_DIR="$PWD/$PROJECT_DIR_NAME"
        mkdir -p "$PROJECT_DIR"

        echo -e "${CYAN}📂 解压备份到项目目录: $PROJECT_DIR${RESET}"

        # 解压配置文件和卷目录
        TMP_DIR=$(mktemp -d)
        tar xzf "$BACKUP_FILE" -C "$TMP_DIR"

        # 恢复 docker-compose.yml
        cp -f "$TMP_DIR/docker-compose.yml" "$PROJECT_DIR/"

        # 恢复卷数据
        for dir in "$TMP_DIR"/*; do
            [[ $(basename "$dir") == "docker-compose.yml" ]] && continue
            target_dir="$PROJECT_DIR/$(basename "$dir")"
            mkdir -p "$target_dir"
            cp -r "$dir/." "$target_dir/"
        done

        rm -rf "$TMP_DIR"

        # 启动容器
        if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器...${RESET}"
            cd "$PROJECT_DIR" || continue
            docker compose up -d
            echo -e "${GREEN}✅ 已恢复: $PROJECT_DIR${RESET}"
        else
            echo -e "${YELLOW}⚠️ docker-compose.yml 不存在，跳过启动容器${RESET}"
        fi
    done
}

# ================== 删除备份 ==================
delete_backup() {
    read -rp "请输入备份存放目录（默认 $DEFAULT_BACKUP_DIR）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}❌ 目录不存在: $BACKUP_DIR${RESET}"
        return
    fi

    ls -1 "$BACKUP_DIR"
    read -rp "请输入要删除的备份文件名（多个用空格分隔）: " -a FILES
    for FILE in "${FILES[@]}"; do
        if [[ -f "$BACKUP_DIR/$FILE" ]]; then
            rm -f "$BACKUP_DIR/$FILE"
            echo -e "${GREEN}✅ 已删除 $FILE${RESET}"
        else
            echo -e "${RED}❌ 文件不存在: $FILE${RESET}"
        fi
    done
}

# ================== 远程备份 ==================
remote_backup() {
    read -rp "请输入要远程传输的备份文件（多个空格分隔）: " -a FILES
    read -rp "请输入远程 VPS 用户名: " REMOTE_USER
    read -rp "请输入远程 VPS IP 或域名: " REMOTE_HOST
    read -rp "请输入远程目录: " REMOTE_DIR
    read -rp "请输入远程 SSH 端口（默认 22）: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}

    for FILE in "${FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo -e "${RED}❌ 文件不存在: $FILE${RESET}"
            continue
        fi
        echo -e "${CYAN}🚀 传输 $FILE → $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR (端口 $REMOTE_PORT)${RESET}"
        scp -P "$REMOTE_PORT" "$FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✅ 传输成功: $FILE${RESET}"
        else
            echo -e "${RED}❌ 传输失败: $FILE${RESET}"
        fi
    done
}

# ================== 菜单 ==================
while true; do
    clear
    echo -e "${CYAN}===== Docker Compose 多项目备份恢复 =====${RESET}"
    echo -e "${GREEN}1. 备份项目（包含卷数据）${RESET}"
    echo -e "${GREEN}2. 恢复项目（自动恢复到原目录${RESET}"
    echo -e "${GREEN}3. 删除备份文件${RESET}"
    echo -e "${GREEN}4. 远程备份到 VPS${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -rp "请选择操作: " CHOICE

    case $CHOICE in
        1) backup ;;
        2) restore ;;
        3) delete_backup ;;
        4) remote_backup ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    echo -e "\n按回车键继续..."
    read
done
