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

# ===== 公钥 + 密码（推荐）=====
enable_pubkey() {
    backup_config

    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$CONFIG"

    echo -e ${GREEN}"✔ 公钥 + 密码登录已开启"${RESET}
    restart_ssh
}

# ===== 仅密码 =====
disable_pubkey() {
    backup_config

    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/' "$CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$CONFIG"

    echo -e ${YELLOW}"✔ 已关闭公钥，仅密码登录"${RESET}
    restart_ssh
}

# ===== 状态 =====
status() {
    echo -e ${GREEN}"====== 当前状态 ======"${RESET}
    grep -E "PubkeyAuthentication|PasswordAuthentication" "$CONFIG"
    echo
}

# ===== 菜单 =====
menu() {
    while true; do
        clear

        echo -e ${GREEN}"============================="${RESET}
        echo -e ${GREEN}"   SSH 公钥管理工具"${RESET}
        echo -e ${GREEN}"============================="${RESET}
        echo -e ${GREEN}"1) 开启公钥登录"${RESET}
        echo -e ${GREEN}"2) 禁用公钥登录"${RESET}
        echo -e ${GREEN}"3) 查看当前状态"${RESET}
        echo -e ${GREEN}"0) 退出"${RESET}
        echo -ne ${GREEN}"请选择操作: "${RESET}
        read num

        case $num in
            1) enable_pubkey ;;
            2) disable_pubkey ;;
            3) status ;;
            0) exit 0 ;;
            *) echo -e ${RED}"无效输入"${RESET} ;;
        esac

        read -rp "回车继续..."
    done
}

menu
