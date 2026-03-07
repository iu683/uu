#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    clear
    echo -e "${GREEN}=== 磁盘空间排查工具 ===${RESET}"
    echo -e "${GREEN}1) 查看磁盘整体使用情况${RESET}"
    echo -e "${GREEN}2) 查看 / 目录占用${RESET}"
    echo -e "${GREEN}3) 查看指定目录占用${RESET}"
    echo -e "${GREEN}4) 查找系统最大文件${RESET}"
    echo -e "${GREEN}5) 查找大于100MB文件${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -r -p $'\033[32m请选择: \033[0m' choice
}

disk_usage() {
    echo -e "${YELLOW}磁盘整体使用情况:${RESET}"
    df -h
}

root_dir_usage() {
    echo -e "${YELLOW}/ 目录占用:${RESET}"
    du -h --max-depth=1 / 2>/dev/null
}

custom_dir_usage() {
    read -p "请输入要查看的目录: " dir
    if [ -d "$dir" ]; then
        du -h --max-depth=1 "$dir"
    else
        echo -e "${RED}目录不存在${RESET}"
    fi
}

largest_files() {
    echo -e "${YELLOW}系统最大文件 (前20):${RESET}"
    du -ah / 2>/dev/null | sort -rh | head -20
}

big_files() {
    echo -e "${YELLOW}大于100MB文件:${RESET}"
    find / -type f -size +100M 2>/dev/null
}

while true; do
    menu
    case $choice in
        1) disk_usage ;;
        2) root_dir_usage ;;
        3) custom_dir_usage ;;
        4) largest_files ;;
        5) big_files ;;
        0) exit ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    echo
    read -p "按回车返回菜单..."
done
