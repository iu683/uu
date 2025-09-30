#!/bin/bash

# ================== 配色 ==================
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 备份函数 ==================
backup() {
    read -rp "请输入要备份的 Docker Compose 项目目录: " PROJECT_DIR
    if [[ ! -d "$PROJECT_DIR" ]]; then
        echo -e "${RED}❌ 目录不存在: $PROJECT_DIR${RESET}"
        return
    fi

    read -rp "请输入备份存放目录（默认 /opt/docker_backups）: " BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-/opt/docker_backups}
    mkdir -p "$BACKUP_DIR"

    TIMESTAMP=$(date +%F_%H-%M-%S)
    BACKUP_FILE="$BACKUP_DIR/$(basename "$PROJECT_DIR")_backup_$TIMESTAMP.tar.gz"

    echo -e "${CYAN}📦 开始压缩项目目录: $PROJECT_DIR → $BACKUP_FILE${RESET}"
    tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" .

    echo -e "${GREEN}✅ 备份完成: $BACKUP_FILE${RESET}"
}

# ================== 恢复函数 ==================
restore() {
    read -rp "请输入备份文件路径: " BACKUP_FILE
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo -e "${RED}❌ 备份文件不存在: $BACKUP_FILE${RESET}"
        return
    fi

    read -rp "请输入恢复到的项目目录（原目录或新目录）: " PROJECT_DIR
    if [[ -z "$PROJECT_DIR" ]]; then
        echo -e "${RED}❌ 项目目录不能为空${RESET}"
        return
    fi

    mkdir -p "$PROJECT_DIR"
    echo -e "${CYAN}📂 解压备份到项目目录: $PROJECT_DIR${RESET}"
    tar xzf "$BACKUP_FILE" -C "$PROJECT_DIR"

    # 启动容器
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        echo -e "${CYAN}🚀 启动容器...${RESET}"
        cd "$PROJECT_DIR" || return
        docker compose up -d
        echo -e "${GREEN}✅ 恢复完成${RESET}"
    else
        echo -e "${RED}❌ docker-compose.yml 不存在，无法启动容器${RESET}"
    fi
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
