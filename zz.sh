#!/usr/bin/env bash
set -e

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak_$(date +%F_%H%M%S)"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ===== 重启 SSH =====
restart_ssh() {
    if command -v systemctl &>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
    else
        service ssh restart 2>/dev/null || service sshd restart
    fi
    echo -e ${GREEN}"✔ SSH 已重启生效"${RESET}
}

# ===== 备份 =====
backup_config() {
    cp "$CONFIG" "$BACKUP"
    echo -e ${YELLOW}"已备份 → $BACKUP"${RESET}
}

# ===== 禁用 root 密码登录（仅密钥）=====
disable_root_password() {
    backup_config

    # 新版本 OpenSSH
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$CONFIG"

    echo -e ${GREEN}"✔ root 已禁止密码登录（仅允许公钥）"${RESET}
    restart_ssh
}

# ===== 恢复 root 密码登录 =====
enable_root_password() {
    backup_config

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$CONFIG"

    echo -e ${YELLOW}"✔ root 已允许密码登录"${RESET}
    restart_ssh
}

# ===== 状态 =====
status() {
    echo -e ${GREEN}"====== 当前 Root 登录策略 ======"${RESET}
    grep PermitRootLogin "$CONFIG"
    echo
}

# ===== 菜单 =====
menu() {
    while true; do
        clear

        echo -e ${GREEN}"===================================="${RESET}
        echo -e ${GREEN}"   Root 密码登录管理工具"${RESET}
        echo -e ${GREEN}"===================================="${RESET}
        echo -e ${GREEN}"1) 禁用 root 密码（仅公钥登录)"${RESET}
        echo -e ${GREEN}"2) 允许 root 密码登录"${RESET}
        echo -e ${GREEN}"3) 查看当前状态"${RESET}
        echo -e ${GREEN}"0) 退出"${RESET}
        echo -ne ${GREEN}"请选择操作: "${RESET}
        read num

        case $num in
            1) disable_root_password ;;
            2) enable_root_password ;;
            3) status ;;
            0) exit 0 ;;
            *) echo -e ${RED}"无效输入"${RESET} ;;
        esac

        read -rp "回车继续..."
    done
}

menu
