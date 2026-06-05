#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
YELLOW="\033[33m"

# =========================================================
# 动态获取 Fail2Ban 的状态、版本、监听端口与拦截数据
# =========================================================
get_fail2ban_status() {
    # 1. 检查运行状态
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        STATUS="${YELLOW}已运行${RESET}"
    else
        STATUS="${RED}未运行${RESET}"
    fi
    
    # 2. 获取版本号
    if command -v fail2ban-client >/dev/null 2>&1; then
        VERSION_SHOW=$(fail2ban-client --version | head -n 1 | awk '{print $2}')
    else
        VERSION_SHOW="未安装"
    fi
    
    # 3. 动态获取 SSH 监听端口（多端口完美清洗版）
    if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
        local port_check=$(grep -E '^\s*port\s*=' /etc/fail2ban/jail.d/sshd.local | \
                           awk -F'=' '{print $2}' | \
                           tr ',' '\n' | \
                           tr -d ' ' | \
                           awk 'NF' | sort -u | \
                           tr '\n' ',' | sed 's/,$//')
        PORT_SHOW=${port_check:-22}
    else
        PORT_SHOW="未知"
    fi
    
    # 4. 统计当前拦截的 IP 总数
    if systemctl is-active --quiet fail2ban 2>/dev/null && command -v fail2ban-client >/dev/null 2>&1; then
        local jails=$(fail2ban-client status | grep "Jail list:" | sed 's/.*Jail list://' | tr ',' ' ')
        local total_banned=0
        for jail in $jails; do
            local count=$(fail2ban-client status "$jail" | grep "Currently banned:" | awk '{print $4}')
            total_banned=$((total_banned + count))
        done
        SITE_COUNT=$total_banned
    else
        SITE_COUNT=0
    fi
}

# =========================================================
# Fail2Ban 功能核心函数
# =========================================================
check_fail2ban() {
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}Fail2Ban 未运行，正在启动...${RESET}"
        systemctl enable --now fail2ban
        sleep 1
    fi
}

install_fail2ban() {
    echo -e "${GREEN}正在安装 Fail2Ban...${RESET}"
    if [ -f /etc/debian_version ]; then
        apt update
        apt install -y fail2ban curl wget
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y fail2ban curl wget
    else
        echo -e "${RED}不支持的操作系统${RESET}"
        exit 1
    fi
    systemctl enable --now fail2ban
    sleep 1
}

# 新增：更新 Fail2Ban 函数
update_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${RED}Fail2Ban 未安装，无法更新，请先选择选项 1 进行安装${RESET}"
        return
    fi
    
    echo -e "${GREEN}正在检查并更新 Fail2Ban...${RESET}"
    if [ -f /etc/debian_version ]; then
        apt update
        apt install --only-upgrade -y fail2ban
    elif [ -f /etc/redhat-release ]; then
        yum update -y fail2ban
    fi
    
    systemctl restart fail2ban
    echo -e "${GREEN}Fail2Ban 更新并重启完成${RESET}"
}

configure_ssh() {
    if [ -f /etc/debian_version ]; then
        LOG_PATH="/var/log/auth.log"
    elif [ -f /etc/redhat-release ]; then
        LOG_PATH="/var/log/secure"
    else
        echo -e "${RED}不支持的操作系统${RESET}"
        exit 1
    fi

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

    systemctl restart fail2ban
    sleep 1
    echo -e "${GREEN}SSH 防暴力破解配置完成${RESET}"
}

uninstall_fail2ban() {
    echo -e "${GREEN}正在卸载 Fail2Ban...${RESET}"
    systemctl stop fail2ban || true
    if [ -f /etc/debian_version ]; then
        apt remove -y fail2ban
    elif [ -f /etc/redhat-release ]; then
        yum remove -y fail2ban
    fi
    echo -e "${GREEN}Fail2Ban 已卸载${RESET}"
}

# =========================================================
# 换装后的全新 Fail2Ban 管理面板 (带端口与更新选项)
# =========================================================
fail2ban_menu() {
    while true; do
        # 每次循环动态更新 Fail2Ban 的数据
        get_fail2ban_status

        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} ◈  SSH 防暴力破解管理面板  ◈  ${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} 状态  : ${STATUS}"
        echo -e "${GREEN} 版本  : ${YELLOW}${VERSION_SHOW}${RESET}"
        echo -e "${GREEN} 端口  : ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${GREEN} 封禁  : ${YELLOW}${SITE_COUNT} 个 IP${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN}  1. 安装开启SSH防护${RESET}"
        echo -e "${GREEN}  2. 关闭SSH防护功能${RESET}"
        echo -e "${GREEN}  3. 配置SSH防护参数${RESET}"
        echo -e "${GREEN}  4. 查看SSH拦截记录${RESET}"
        echo -e "${GREEN}  5. 查看当前防御规则列表${RESET}"
        echo -e "${GREEN}  6. 查看日志实时监控${RESET}"
        echo -e "${GREEN}  7. 卸载 Fail2Ban${RESET}"
        echo -e "${GREEN}  8. 更新 Fail2Ban${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        
        read -r choice </dev/tty

        case $choice in
            1)
                if ! command -v fail2ban-client >/dev/null 2>&1; then
                    install_fail2ban
                else
                    systemctl enable --now fail2ban
                fi
                configure_ssh
                ;;
            2)
                check_fail2ban
                if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
                    sed -i '/enabled/s/true/false/' /etc/fail2ban/jail.d/sshd.local
                    systemctl restart fail2ban
                    sleep 1
                    echo -e "${GREEN}SSH 防暴力破解已关闭${RESET}"
                else
                    echo -e "${RED}SSH 配置文件不存在，请先安装并开启 SSH 防护${RESET}"
                fi
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            3)
                check_fail2ban
                if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
                    configure_ssh
                else
                    echo -e "${RED}SSH 配置文件不存在，请先安装并开启 SSH 防护${RESET}"
                fi
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            4)
                check_fail2ban
                echo -e "${GREEN}当前被封禁的 IP 列表:${RESET}"
                BANNED=$(fail2ban-client status sshd | grep 'Banned IP list' | cut -d: -f2)
                if [ -z "$BANNED" ]; then
                    echo -e "${GREEN}无${RESET}"
                else
                    echo -e "${GREEN}$BANNED${RESET}"
                fi
                echo -e "${GREEN}✅ 状态显示完成${RESET}"
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            5)
                check_fail2ban
                echo -e "${GREEN}当前防御规则列表:${RESET}"
                JAILS=$(fail2ban-client status | grep 'Jail list' | cut -d: -f2)
                if [ -z "$JAILS" ]; then
                    echo -e "${GREEN}无${RESET}"
                else
                    echo -e "${GREEN}$JAILS${RESET}"
                fi
                echo -e "${GREEN}✅ 状态显示完成${RESET}"
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            6)
                check_fail2ban
                echo -e "${GREEN}进入日志实时监控，按 Ctrl+C 返回菜单${RESET}"
                trap 'echo -e "\n${GREEN}已退出日志监控，返回菜单${RESET}"' SIGINT
                tail -n 20 -f /var/log/fail2ban.log || true
                trap - SIGINT
                read -p $'\033[32m按回车继续...\033[0m'
                ;;
            7)
                uninstall_fail2ban
                break
                ;;
            8)
                update_fail2ban
                read -p $'\033[32m按回车返回菜单...\033[0m'
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入${RESET}"
                sleep 1
                ;;
        esac
    done
}

# =========================================================
# 执行主逻辑
# =========================================================
fail2ban_menu
