#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

SET_KEY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/secretkey.sh"
MANAGE_KEY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/SSHPubkey.sh"

#################################
# 执行远程脚本
#################################
run_script() {
    url=$1
    name=$2

    echo -e "${GREEN}正在执行：${name}${RESET}"
    bash <(curl -fsSL "$url")
    pause
}

#################################
# 一键清除 SSH 密钥
#################################
clear_all_ssh_keys() {
    echo -e "${RED}警告：此操作将删除所有用户 SSH 密钥！${RESET}"
    echo -e "${RED}包括：/root/.ssh 和 /home/*/.ssh${RESET}"
    read -p $'\033[33m确认清除请输入(yes): \033[0m' confirm

    if [[ "$confirm" != "yes" ]]; then
        echo -e "${GREEN}已取消${RESET}"
        sleep 1
        menu
        return
    fi

    echo -e "${GREEN}正在清理 SSH 密钥...${RESET}"

    rm -rf /root/.ssh /home/*/.ssh 2>/dev/null

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    echo -e "${GREEN}SSH 密钥已全部清理完成${RESET}"
    pause
}

#################################
# 暂停
#################################
pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

#################################
# 主菜单
#################################
menu() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      root 公钥登录管理         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 设置公钥登录${RESET}"
    echo -e "${GREEN} 2) 管理公钥登录${RESET}"
    echo -e "${GREEN} 3) 一键清除所有SSH密钥${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) run_script "$SET_KEY_URL" "设置公钥登录" ;;
        2) run_script "$MANAGE_KEY_URL" "管理公钥登录" ;;
        3) clear_all_ssh_keys ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
