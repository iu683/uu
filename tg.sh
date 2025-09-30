#!/bin/bash

# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 备份函数（支持多个项目） ==================
backup() {
    read -rp "请输入要备份的 Docker Compose 项目目录（可多选，用空格分隔）: " -a PROJECT_DIRS
    if [[ ${#PROJECT_DIRS[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 没有输入项目目录${RESET}"
        return
    fi

    read -rp "请输入备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    mkdir -p "$BACKUP_DIR"

    for PROJECT_DIR in "${PROJECT_DIRS[@]}"; do
        if [[ ! -d "$PROJECT_DIR" ]]; then
            echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"
            continue
        fi

        TIMESTAMP=$(date +%F_%H-%M-%S)
        BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup_$TIMESTAMP.tar.gz"

        echo -e "${CYAN}📦 开始压缩项目目录: $PROJECT_DIR → $BACKUP_FILE${RESET}"
        tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" .

        echo -e "${GREEN}✅ 已完成备份: $BACKUP_FILE${RESET}"
    done

    # 远程备份
    read -rp "是否上传到远程 VPS？(y/N): " UPLOAD
    if [[ "$UPLOAD" =~ ^[Yy]$ ]]; then
        read -rp "请输入远程用户@IP: " REMOTE
        read -rp "请输入远程目录（默认 /opt/docker_backups）: " REMOTE_DIR
        REMOTE_DIR=${REMOTE_DIR:-/opt/docker_backups}
        read -rp "请输入 SSH 端口（默认 22）: " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}

        for FILE in "$BACKUP_DIR"/*.tar.gz; do
            echo -e "${CYAN}📤 上传 $FILE → $REMOTE:$REMOTE_DIR${RESET}"
            scp -P "$SSH_PORT" "$FILE" "$REMOTE:$REMOTE_DIR"
        done
        echo -e "${GREEN}✅ 远程上传完成${RESET}"
    fi
}

# ================== 恢复函数（支持多个备份文件，默认 /opt/原项目名） ==================
restore() {
    read -rp "请输入备份文件路径（可多选，用空格分隔）: " -a BACKUP_FILES
    if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
        echo -e "${RED}❌ 没有选择备份文件${RESET}"
        return
    fi

    read -rp "请输入恢复到的项目目录（默认 /opt/原项目名）: " PROJECT_DIR_INPUT
    for FILE in "${BACKUP_FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo -e "${RED}❌ 文件不存在: $FILE${RESET}"
            continue
        fi

        BASE_NAME=$(basename "$FILE" | sed 's/_backup_.*\.tar\.gz//')
        # 默认路径改为 /opt/原项目名
        TARGET_DIR=${PROJECT_DIR_INPUT:-/opt/$BASE_NAME}
        mkdir -p "$TARGET_DIR"

        echo -e "${CYAN}📂 解压备份 $FILE → $TARGET_DIR${RESET}"
        tar xzf "$FILE" -C "$TARGET_DIR"

        # 启动容器
        if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
            echo -e "${CYAN}🚀 启动容器...${RESET}"
            cd "$TARGET_DIR" || continue
            docker compose up -d
            echo -e "${GREEN}✅ 恢复完成: $TARGET_DIR${RESET}"
        else
            echo -e "${RED}❌ docker-compose.yml 不存在，无法启动容器${RESET}"
        fi
    done
}


# ================== 删除备份 ==================
delete_backup() {
    read -rp "请输入备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}❌ 目录不存在: $BACKUP_DIR${RESET}"
        return
    fi

    ls -1 "$BACKUP_DIR"
    read -rp "请输入要删除的备份文件名: " FILE
    if [[ -f "$BACKUP_DIR/$FILE" ]]; then
        rm -f "$BACKUP_DIR/$FILE"
        echo -e "${GREEN}✅ 已删除 $FILE${RESET}"
    else
        echo -e "${RED}❌ 文件不存在${RESET}"
    fi
}

# ================== 菜单 ==================
while true; do
    clear
    echo -e "${CYAN}===== Docker Compose 项目备份与恢复 =====${RESET}"
    echo -e "${GREEN}1. 备份项目${RESET}"
    echo -e "${GREEN}2. 恢复项目${RESET}"
    echo -e "${GREEN}3. 删除备份文件${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -rp "请选择操作: " CHOICE

    case $CHOICE in
        1) backup ;;
        2) restore ;;
        3) delete_backup ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择${RESET}" ;;
    esac
    echo -e "\n按回车键继续..."
    read
done
