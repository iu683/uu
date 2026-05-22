#!/bin/bash
# ========================================
# Rhex 备份恢复脚本
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

APP_DIR="/opt/Rhex"
BACKUP_DIR="/opt/Rhexbackups"

mkdir -p "$BACKUP_DIR"

cd "$APP_DIR" || exit 1

backup() {
    echo -e "${GREEN}开始数据库备份...${RESET}"

    docker compose --profile backup run --rm postgres-backup

    echo -e "${GREEN}开始文件备份...${RESET}"

    FILE_NAME="rhex-files-$(date +%Y%m%d-%H%M%S).tar.gz"

    tar -czf "$BACKUP_DIR/$FILE_NAME" \
        uploads \
        addons \
        .env \
        docker-compose.yml

    echo
    echo -e "${GREEN}备份完成${RESET}"
    echo -e "${GREEN}文件:${RESET} $BACKUP_DIR/$FILE_NAME"
}

restore() {
    echo -e "${GREEN}可用备份:${RESET}"
    echo

    ls "$BACKUP_DIR"

    echo
    read -rp "请输入要恢复的文件备份名: " FILE

    if [ ! -f "$BACKUP_DIR/$FILE" ]; then
        echo -e "${RED}备份文件不存在${RESET}"
        return
    fi

    echo
    read -rp "确认恢复？会覆盖现有文件！(y/N): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}已取消${RESET}"
        return
    fi

    echo -e "${GREEN}恢复文件中...${RESET}"

    tar -xzf "$BACKUP_DIR/$FILE" -C "$APP_DIR"

    echo -e "${GREEN}恢复完成${RESET}"
}

while true; do
    clear
    echo -e "${GREEN}==== Rhex 备份恢复管理====${RESET}"
    echo -e "${GREEN}1. 备份${RESET}"
    echo -e "${GREEN}2. 恢复${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -rp "$(echo -e "${GREEN}请输入选项: ${RESET}")" CHOICE

    case $CHOICE in
        1)
            backup
            read -rp "按回车继续..."
            ;;
        2)
            restore
            read -rp "按回车继续..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            sleep 1
            ;;
    esac
done
