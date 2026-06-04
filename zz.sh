#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak"

# 判断是否为 Alpine 系统
IS_ALPINE=false
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=true
fi

#################################
# 核心函数：安全修改 SSH 配置（解决子配置文件覆盖问题）
#################################
modify_ssh_config() {
    local key=$1
    local value=$2

    # 1. 备份主配置
    [ -f "$CONFIG" ] && [ ! -f "$BACKUP" ] && cp "$CONFIG" "$BACKUP"

    # 2. 修改主配置文件
    if grep -q -i "^[# ]*${key}" "$CONFIG"; then
        sed -i "s|^[# ]*${key}.*|${key} ${value}|g" "$CONFIG"
    else
        echo "${key} ${value}" >> "$CONFIG"
    fi

    # 3. 注释掉子配置文件（sshd_config.d/*.conf）中的冲突项，确保主配置绝对生效
    if [ -d "/etc/ssh/sshd_config.d" ]; then
        for sub_conf in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$sub_conf" ]; then
                sed -i "s|^[ ]*${key}|#&|g" "$sub_conf" 2>/dev/null
            fi
        done
    fi
}

#################################
# SSH 服务重启与备份
#################################
restart_ssh() {
    if [ "$IS_ALPINE" = true ]; then
        rc-service sshd restart 2>/dev/null
    else
        if command -v systemctl &>/dev/null; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        else
            service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
        fi
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
        STATUS_FILE="${YELLOW}[正常] ( ${count} 个公钥)${RESET}"
    else
        STATUS_FILE="${RED}[未设置]${RESET}"
    fi

    # 获取 SSH 实际生效配置
    local sshd_vars=$(sshd -T 2>/dev/null)
    if [ -z "$sshd_vars" ]; then
        sshd_vars=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
    fi

    local pubkey_status=$(echo "$sshd_vars" | grep -i "^pubkeyauthentication" | awk '{print $2}' | tr 'A-Z' 'a-z' | head -n 1)
    local root_login_status=$(echo "$sshd_vars" | grep -i "^permitrootlogin" | awk '{print $2}' | tr 'A-Z' 'a-z' | head -n 1)
    local pass_status=$(echo "$sshd_vars" | grep -i "^passwordauthentication" | awk '{print $2}' | tr 'A-Z' 'a-z' | head -n 1)

    # ---- 2. 检测公钥总开关状态 ----
    if [[ "$pubkey_status" == "no" ]]; then
        STATUS_PUBKEY="${RED}[已禁用]${RESET}"
    else
        STATUS_PUBKEY="${YELLOW}[已开启]${RESET}"
    fi

    # ---- 3. 检测 Root 登录及密码登录状态 ----
    local root_str=""
    if [[ "$root_login_status" == "no" || "$root_login_status" == "forced-commands-only" ]]; then
        root_str="${RED}Root已禁${RESET}"
    else
        root_str="${YELLOW}Root允许${RESET}"
    fi

    local pass_str=""
    if [[ "$pass_status" == "no" ]]; then
        pass_str="${RED}密码登录:关${RESET}"
    else
        pass_str="${YELLOW}密码登录:开${RESET}"
    fi
    
    STATUS_ROOT="[${root_str} / ${pass_str}]"
}

#################################
# 选项 2 的管理公钥登录（子菜单）
#################################
manage_key_menu() {
    while true; do
        clear
        # 修复点：子菜单顶端同样加上状态刷新显示
        get_each_ssh_status
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}       管理公钥登录配置         ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} ${STATUS_FILE}"
        echo -e "${GREEN}公钥登录 :${RESET} ${STATUS_PUBKEY}"
        echo -e "${GREEN}密码登录 :${RESET} ${STATUS_ROOT}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1) 开启公钥+密码登录(推荐)${RESET}"
        echo -e "${GREEN} 2) 切换密码登录(关闭公钥)${RESET}"
        echo -e "${GREEN} 0) 返回主菜单${RESET}"
        read -p $'\033[32m 请选择: \033[0m' sub_choice

        case $sub_choice in
            1)
                modify_ssh_config "PubkeyAuthentication" "yes"
                modify_ssh_config "PasswordAuthentication" "yes"
                echo -e "${GREEN}✔ 公钥 + 密码登录已开启${RESET}"
                restart_ssh
                pause
                ;;
            2)
                modify_ssh_config "PubkeyAuthentication" "no"
                modify_ssh_config "PasswordAuthentication" "yes"
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
# 本地生成并配置密钥登录（修复密码设置与路径报错）
#################################
setup_local_ssh_key() {
    echo -e "${YELLOW}开始生成 SSH 密钥并配置公钥登录...${RESET}"
    
    if [ "$IS_ALPINE" = true ]; then
        apk add --no-cache openssh-client openssh-server >/dev/null 2>&1
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    read -p "请输入密钥保存路径（默认 /root/.ssh/id_ed25519）: " input_path
    
    local keypath="${input_path}"
    if [ -z "$keypath" ]; then
        keypath="/root/.ssh/id_ed25519"
    fi

    # 避免重复生成导致覆盖
    if [ -f "$keypath" ]; then
        read -p "密钥已存在，是否覆盖？(y/n): " overwrite
        if [[ "$overwrite" != "y" ]]; then
            echo -e "${YELLOW}已取消生成，使用原有密钥配置...${RESET}"
        else
            # 修复点：移除了原本错误的 -f "" 串行，保留正常交互，用户可直接设置公钥密码短语
            ssh-keygen -t ed25519 -f "$keypath"
        fi
    else
        # 修复点：移除了原本错误的 -f ""
        ssh-keygen -t ed25519 -f "$keypath"
    fi

    if [ -f "${keypath}.pub" ]; then
        cat "${keypath}.pub" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        
        modify_ssh_config "PubkeyAuthentication" "yes"
        
        echo -e "${GREEN}✔ 密钥登录配置完成${RESET}"
        echo "公钥路径: ${keypath}.pub"
        echo "私钥路径: ${keypath}"
        echo -e "\n${GREEN}================== 您的私钥内容 ==================${RESET}"
        cat "$keypath"
        echo -e "${GREEN}==================================================${RESET}"
        echo -e "${YELLOW}请务必复制上方私钥并妥善保存！${RESET}"
        echo -e "${YELLOW}提示：如果您刚才设置了密码（Passphrase），请在连接时一并输入。${RESET}"
    else
        echo -e "${RED}错误：密钥生成失败！${RESET}"
    fi
    restart_ssh
    pause
}

#################################
# 禁用 root 密码登录（极致安全加固）
#################################
disable_root_password() {
    # 安全检查：如果没有设置公钥，警告用户
    if [ ! -f "/root/.ssh/authorized_keys" ] || [ ! -s "/root/.ssh/authorized_keys" ]; then
        echo -e "${RED}严重警告：检测到您还未设置任何公钥！${RESET}"
        echo -e "${RED}此时禁用密码登录将导致您完全无法通过 SSH 连上这台服务器！${RESET}"
        read -p $'\033[33m确定要继续吗？请输入(yes_i_know): \033[0m' extreme_confirm
        if [[ "$extreme_confirm" != "yes_i_know" ]]; then
            echo -e "${GREEN}已紧急取消操作，建议先设置公钥。${RESET}"
            sleep 2
            return
        fi
    fi

    echo -e "${YELLOW}正在安全加固：禁用 root 密码登录...${RESET}"
    
    # 使用强效修改机制，防止云厂商子配置文件覆盖
    modify_ssh_config "PermitRootLogin" "prohibit-password"
    modify_ssh_config "PasswordAuthentication" "no"

    echo -e "${GREEN}✔ root 密码登录已禁用，现在仅允许公钥登录${RESET}"
    restart_ssh
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
    echo -e "${GREEN}       root 公钥登录管理         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前状态 :${RESET} ${STATUS_FILE}"
    echo -e "${GREEN}公钥登录 :${RESET} ${STATUS_PUBKEY}"
    echo -e "${GREEN}密码登录 :${RESET} ${STATUS_ROOT}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1) 设置公钥登录${RESET}"
    echo -e "${GREEN} 2) 管理公钥登录${RESET}"
    echo -e "${GREEN} 3) 禁用root登录${RESET}"
    echo -e "${GREEN} 4) 清除SSH公钥${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) setup_local_ssh_key ;; 
        2) manage_key_menu ;; 
        3) disable_root_password ;; 
        4) clear_all_ssh_keys ;;
        0) 
            exit 0 
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            ;;
    esac
done
