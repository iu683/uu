#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak"

SET_KEY_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/secretkey.sh"

#################################
# SSH 服务重启与备份
#################################
restart_ssh() {
    if command -v systemctl &>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    else
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    fi
    echo -e "${GREEN}✔ SSH 已重启生效${RESET}"
}

backup_config() {
    cp "$CONFIG" "$BACKUP" 2>/dev/null
    echo -e "${YELLOW}已备份 → $BACKUP${RESET}"
}

#################################
# 分离获取 3 个核心状态
#################################
get_each_ssh_status() {
    # ---- 1. 检测公钥文件状态 ----
    if [ -f "/root/.ssh/authorized_keys" ] && [ -s "/root/.ssh/authorized_keys" ]; then
        local count=$(wc -l < /root/.ssh/authorized_keys)
        STATUS_FILE="${GREEN}[正常] (共 ${count} 个公钥)${RESET}"
    else
        STATUS_FILE="${RED}[未设置] (文件不存在或为空)${RESET}"
    fi

    # 获取 SSH 实际生效配置
    local sshd_vars=$(sshd -T 2>/dev/null)
    if [ -z "$sshd_vars" ]; then
        sshd_vars=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
    fi

    local pubkey_status=$(echo "$sshd_vars" | grep -i "^pubkeyauthentication" | awk '{print $2}' | tr 'A-Z' 'a-z' | head -n 1)
    local root_login_status=$(echo "$sshd_vars" | grep -i "^permitrootlogin" | awk '{print $2}' | tr 'A-Z' 'a-z' | head -n 1)

    # ---- 2. 检测公钥总开关状态 ----
    if [[ "$pubkey_status" == "no" ]]; then
        STATUS_PUBKEY="${RED}[已禁用] (PubkeyAuthentication=no)${RESET}"
    else
        STATUS_PUBKEY="${GREEN}[已开启] (PubkeyAuthentication=yes)${RESET}"
    fi

    # ---- 3. 检测 Root 登录状态 ----
    if [[ "$root_login_status" == "no" || "$root_login_status" == "forced-commands-only" ]]; then
        STATUS_ROOT="${RED}[已禁用] (PermitRootLogin=no)${RESET}"
    else
        STATUS_ROOT="${GREEN}[已开启] (${root_login_status})${RESET}"
    fi
}

#################################
# 选项 2 的管理公钥登录（子菜单）
#################################
manage_key_menu() {
    while true; do
        clear
        echo -e "${GREEN}======管理公钥登录配置======${RESET}"
        echo -e "${GREEN} 1.开启 公钥+密码登录 (推荐)${RESET}"
        echo -e "${GREEN} 2.切换为仅密码登录(关闭公钥)${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        read -p $'\033[32m 请选择: \033[0m' sub_choice

        case $sub_choice in
            1)
                backup_config
                sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$CONFIG"
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$CONFIG"
                echo -e "${GREEN}✔ 公钥 + 密码登录已开启${RESET}"
                restart_ssh
                pause
                ;;
            2)
                backup_config
                sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/' "$CONFIG"
                sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$CONFIG"
                echo -e "${YELLOW}✔ 已关闭公钥，仅密码登录${RESET}"
                restart_ssh
                pause
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}输入错误，请重新选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

#################################
# 执行远程脚本 (用于选项1)
#################################
run_script() {
    local url=$1
    local name=$2

    echo -e "${GREEN}正在执行：${name}${RESET}"
    bash <(curl -fsSL "$url")
    pause
}

#################################
# 一键清除 SSH 密钥
#################################
clear_all_ssh_keys() {
    echo -e "${RED}警告：此操作将删除所有用户 SSH 密钥！${RESET}"
    read -p $'\033[33m确认清除请输入(y): \033[0m' confirm

    if [[ "$confirm" != "y" ]]; then
        echo -e "${GREEN}已取消操作${RESET}"
        sleep 1
        return
    fi

    echo -e "${GREEN}正在清理 SSH 密钥...${RESET}"
    rm -rf /root/.ssh /home/*/.ssh 2>/dev/null
    restart_ssh
    echo -e "${GREEN}SSH 密钥已全部清理完成${RESET}"
    pause
}

#################################
# 暂停提示
#################################
pause() {
    read -p $'\033[32m按回车继续...\033[0m'
}

#################################
# 主循环菜单
#################################
while true; do
    clear
    get_each_ssh_status

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     root 公钥登录管理          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前状态 :${RESET} ${STATUS_LABEL}"
    echo -e "${GREEN}公钥登录 :${RESET} ${STATUS_PUBKEY}"
    echo -e "${GREEN}密码登录 :${RESET} ${STATUS_LABEL}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 设置公钥登录${RESET}"
    echo -e "${GREEN} 2) 管理公钥登录${RESET}"
    echo -e "${GREEN} 3) 清除所有SSH密钥${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) run_script "$SET_KEY_URL" "设置公钥登录" ;;
        2) manage_key_menu ;; 
        3) clear_all_ssh_keys ;;
        0) 
            exit 0 
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            ;;
    esac
done
