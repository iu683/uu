#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
YELLOW="\033[33m"

# 识别系统和初始化管理器
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    INIT="openrc"
elif [ -f /etc/debian_version ]; then
    OS="debian"
    INIT="systemd"
elif [ -f /etc/redhat-release ]; then
    OS="rhel"
    INIT="systemd"
else
    OS="unknown"
    INIT="unknown"
fi

# 通用服务管理函数
manage_service() {
    local action=$1 # start, stop, restart, enable
    local service="fail2ban"

    if [ "$INIT" == "systemd" ]; then
        case $action in
            enable) systemctl enable --now $service ;;
            *) systemctl $action $service ;;
        esac
    elif [ "$INIT" == "openrc" ]; then
        case $action in
            enable) rc-update add $service default && rc-service $service start ;;
            start) rc-service $service start ;;
            stop) rc-service $service stop ;;
            restart) rc-service $service restart ;;
        esac
    fi
}

# 检查 Fail2Ban 是否运行
check_fail2ban() {
    local running=false
    if [ "$INIT" == "systemd" ]; then
        systemctl is-active --quiet fail2ban && running=true
    elif [ "$INIT" == "openrc" ]; then
        rc-service fail2ban status | grep -q "started" && running=true
    fi

    if [ "$running" == false ]; then
        echo -e "${YELLOW}Fail2Ban 未运行，正在尝试启动...${RESET}"
        manage_service start || echo -e "${RED}启动失败，请检查是否已安装${RESET}"
        sleep 1
    fi
}

# 安装 Fail2Ban
install_fail2ban() {
    echo -e "${GREEN}正在安装 Fail2Ban...${RESET}"
    case "$OS" in
        alpine)
            apk update
            apk add fail2ban curl wget
            # Alpine 需要手动创建日志文件，否则 fail2ban 可能启动失败
            touch /var/log/fail2ban.log
            ;;
        debian)
            apt update
            apt install -y fail2ban curl wget
            ;;
        rhel)
            yum install -y epel-release
            yum install -y fail2ban curl wget
            ;;
        *)
            echo -e "${RED}不支持的操作系统${RESET}"
            exit 1
            ;;
    esac
    manage_service enable
    sleep 1
}

# 配置 SSH 防护
configure_ssh() {
    case "$OS" in
        debian) LOG_PATH="/var/log/auth.log" ;;
        rhel)   LOG_PATH="/var/log/secure" ;;
        alpine) LOG_PATH="/var/log/messages" ;; # Alpine 默认日志位置
    esac

    read -p $'\033[32m请输入 SSH 端口（默认22）: \033[0m' SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    read -p $'\033[32m请输入最大失败尝试次数 maxretry（默认5）: \033[0m' MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}

    read -p $'\033[32m请输入封禁时间 bantime(秒，默认600) : \033[0m' BAN_TIME
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

    manage_service restart
    sleep 1
    echo -e "${GREEN}SSH 防暴力破解配置完成${RESET}"
}

# 卸载 Fail2Ban
uninstall_fail2ban() {
    echo -e "${GREEN}正在卸载 Fail2Ban...${RESET}"
    manage_service stop || true
    case "$OS" in
        alpine) apk del fail2ban ;;
        debian) apt remove -y fail2ban ;;
        rhel)   yum remove -y fail2ban ;;
    esac
    echo -e "${GREEN}Fail2Ban 已卸载${RESET}"
}

# 菜单逻辑（保持原样，但调用适配后的函数）
fail2ban_menu() {
    while true; do
        clear
        echo -e "${GREEN}==== SSH 防暴力破解管理菜单 ====${RESET}"
        echo -e "${GREEN}1. 安装开启 SSH 防暴力破解${RESET}"
        echo -e "${GREEN}2. 关闭 SSH 防暴力破解 (仅停用规则)${RESET}"
        echo -e "${GREEN}3. 配置 SSH 防护参数${RESET}"
        echo -e "${GREEN}4. 查看 SSH 拦截记录${RESET}"
        echo -e "${GREEN}5. 查看防御规则列表${RESET}"
        echo -e "${GREEN}6. 查看日志实时监控${RESET}"
        echo -e "${GREEN}7. 卸载防御程序${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        read -p $'\033[32m请输入你的选择: \033[0m' sub_choice

        case $sub_choice in
            1)
                if ! command -v fail2ban-client >/dev/null 2>&1; then
                    install_fail2ban
                else
                    manage_service start
                fi
                configure_ssh
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            2)
                if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
                    sed -i '/enabled/s/true/false/' /etc/fail2ban/jail.d/sshd.local
                    manage_service restart
                    echo -e "${GREEN}SSH 防暴力破解已关闭${RESET}"
                else
                    echo -e "${RED}配置文件不存在${RESET}"
                fi
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            3)
                check_fail2ban && configure_ssh
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            4)
                check_fail2ban
                echo -e "${GREEN}当前被封禁的 IP 列表:${RESET}"
                fail2ban-client status sshd | grep "Banned IP list"
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            5)
                check_fail2ban
                fail2ban-client status
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            6)
                echo -e "${GREEN}实时监控 /var/log/fail2ban.log (Ctrl+C 退出)${RESET}"
                tail -f /var/log/fail2ban.log
                ;;
            7)
                uninstall_fail2ban
                break
                ;;
            0) break ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

fail2ban_menu
