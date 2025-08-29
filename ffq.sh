#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

LOG_PATH=""

# -------------------------
# 检查系统
# -------------------------
if [[ ! -f /etc/alpine-release ]]; then
    echo -e "${RED}❌ 本脚本仅适用于 Alpine Linux${RESET}"
    exit 1
fi

# -------------------------
# 安装 Fail2Ban 和 rsyslog
# -------------------------
install_fail2ban() {
    echo -e "${GREEN}更新apk索引并安装 fail2ban 和 rsyslog...${RESET}"
    apk update
    apk add fail2ban rsyslog openssh

    rc-update add rsyslog
    service rsyslog start

    rc-update add sshd
    service sshd start

    rc-update add fail2ban
    service fail2ban start

    # 设置 SSH 日志输出
    if ! grep -q "^SyslogFacility AUTH" /etc/ssh/sshd_config; then
        echo "SyslogFacility AUTH" >> /etc/ssh/sshd_config
        echo "LogLevel INFO" >> /etc/ssh/sshd_config
        service sshd restart
    fi

    # 自动检测日志路径
    if [[ -f /var/log/auth.log ]]; then
        LOG_PATH="/var/log/auth.log"
    elif [[ -f /var/log/messages ]]; then
        LOG_PATH="/var/log/messages"
    else
        touch /var/log/messages
        LOG_PATH="/var/log/messages"
    fi

    echo -e "${GREEN}✅ Fail2Ban 已安装并启动，日志文件: $LOG_PATH${RESET}"
}

# -------------------------
# 配置 SSH 防护
# -------------------------
configure_ssh() {
    read -p $'\033[32m请输入 SSH 端口（默认22）: \033[0m' SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    read -p $'\033[32m请输入最大失败尝试次数 maxretry（默认5）: \033[0m' MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}

    read -p $'\033[32m请输入封禁时间 bantime(秒，默认600): \033[0m' BAN_TIME
    BAN_TIME=${BAN_TIME:-600}

    mkdir -p /etc/fail2ban/jail.d
    cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $LOG_PATH
maxretry = $MAX_RETRY
bantime  = $BAN_TIME
EOF

    service fail2ban restart
    echo -e "${GREEN}✅ SSH 防暴力破解配置完成${RESET}"
}

# -------------------------
# 卸载 Fail2Ban
# -------------------------
uninstall_fail2ban() {
    echo -e "${GREEN}正在卸载 Fail2Ban...${RESET}"
    service fail2ban stop || true
    apk del fail2ban rsyslog
    [[ -f /etc/ssh/sshd_config ]] && sed -i '/SyslogFacility AUTH/d;/LogLevel INFO/d' /etc/ssh/sshd_config
    echo -e "${GREEN}✅ Fail2Ban 已卸载${RESET}"
}

# -------------------------
# 查看被封禁 IP
# -------------------------
view_banned() {
    if command -v fail2ban-client &>/dev/null; then
        BANNED=$(fail2ban-client status sshd 2>/dev/null | grep 'Banned IP list' | cut -d: -f2 | xargs)
        echo -e "${GREEN}当前被封禁的 IP:${RESET} ${BANNED:-无}"
    else
        echo -e "${RED}Fail2Ban 未安装或未启动${RESET}"
    fi
    read -p $'\033[32m按回车返回菜单...\033[0m'
}

# -------------------------
# 查看规则列表
# -------------------------
view_jails() {
    if command -v fail2ban-client &>/dev/null; then
        JAILS=$(fail2ban-client status 2>/dev/null | grep 'Jail list' | cut -d: -f2 | xargs)
        echo -e "${GREEN}当前防御规则列表:${RESET} ${JAILS:-无}"
    else
        echo -e "${RED}Fail2Ban 未安装或未启动${RESET}"
    fi
    read -p $'\033[32m按回车返回菜单...\033[0m'
}

# -------------------------
# 日志实时监控
# -------------------------
monitor_log() {
    if [[ -f "$LOG_PATH" ]]; then
        echo -e "${GREEN}进入日志实时监控，按 Ctrl+C 返回菜单${RESET}"
        trap 'echo -e "\n${GREEN}已退出日志监控${RESET}"' SIGINT
        tail -n 20 -f "$LOG_PATH" || true
        trap - SIGINT
    else
        echo -e "${RED}日志文件不存在${RESET}"
    fi
    read -p $'\033[32m按回车返回菜单...\033[0m'
}

# -------------------------
# 菜单
# -------------------------
while true; do
    clear
    echo -e "${GREEN}Alpine Linux SSH 防暴力破解管理菜单${RESET}"
    echo -e "${GREEN}---------------------------------${RESET}"
    echo -e "${GREEN}1. 安装并开启 SSH 防暴力破解${RESET}"
    echo -e "${GREEN}2. 配置 SSH 防护参数${RESET}"
    echo -e "${GREEN}3. 查看被封禁 IP${RESET}"
    echo -e "${GREEN}4. 查看规则列表${RESET}"
    echo -e "${GREEN}5. 日志实时监控${RESET}"
    echo -e "${GREEN}6. 卸载 Fail2Ban${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}---------------------------------${RESET}"

    read -p $'\033[32m请输入你的选择: \033[0m' choice

    case "$choice" in
        1)
            install_fail2ban
            configure_ssh
            read -p $'\033[32m按回车返回菜单...\033[0m'
            ;;
        2)
            configure_ssh
            ;;
        3)
            view_banned
            ;;
        4)
            view_jails
            ;;
        5)
            monitor_log
            ;;
        6)
            uninstall_fail2ban
            read -p $'\033[32m按回车返回菜单...\033[0m'
            ;;
        0)
            break
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            sleep 1
            ;;
    esac
done
