#!/bin/sh
set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
YELLOW="\033[33m"

# =========================================================
# 动态获取 Fail2Ban 的状态、版本、监听端口与拦截数据
# =========================================================
# =========================================================
# 动态获取 Fail2Ban 的状态、版本、监听端口与拦截数据
# =========================================================
get_fail2ban_status() {
    # 1. 检查运行状态 (Alpine OpenRC)
    if rc-service fail2ban status 2>/dev/null | grep -q "started"; then
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
    
    # 3. 动态获取 SSH 监听端口（支持多端口，完美兼容 jail.local 与 jail.d/ 目录）
    port_check=""
    # 罗列所有可能的配置文件，按优先级从高到低排序
    config_files="/etc/fail2ban/jail.d/sshd.local /etc/fail2ban/jail.d/sshd.conf /etc/fail2ban/jail.local"
    
    for file in $config_files; do
        if [ -f "$file" ]; then
            # 精准提取 [sshd] 段落下的 port 配置，防止误抓其他服务的端口
            port_check=$(sed -n '/^\[sshd\]/,/^\[/p' "$file" | sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([^#]*\)/\1/p' | head -n 1 | tr -d '[:space:]')
            if [ -n "$port_check" ]; then
                break
            fi
        fi
    done
    
    # 【降级兜底】如果配置文件里全都没写，直接去抓系统当前 sshd 真正监听的端口
    if [ -z "$port_check" ]; then
        sys_ports=""
        if command -v ss >/dev/null 2>&1; then
            # 兼容 Alpine 纯净版或带守护进程名的 ss 输出
            sys_ports=$(ss -tlnp 2>/dev/null | grep -E 'sshd|:22 ' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -nu | tr '\n' ',' | sed 's/,$//')
        fi
        PORT_SHOW=${sys_ports:-22}
    else
        PORT_SHOW="$port_check"
    fi
    
    # 如果检测到服务名为 "ssh"，自动格式化为数字 "22"
    if [ "$PORT_SHOW" = "ssh" ]; then
        PORT_SHOW="22"
    fi
    
    # 4. 统计当前拦截的 IP 总数
    if rc-service fail2ban status 2>/dev/null | grep -q "started" && command -v fail2ban-client >/dev/null 2>&1; then
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list://' | tr ',' ' ')
        total_banned=0
        for jail in $jails; do
            # 增加容错：确保 jail 名字不为空
            [ -z "$jail" ] && continue
            count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $4}')
            if [ -n "$count" ]; then
                total_banned=$((total_banned + count))
            fi
        done
        SITE_COUNT=$total_banned
    else
        SITE_COUNT=0
    fi
}

# =========================================================
# Fail2Ban 功能核心函数 (Alpine 适配)
# =========================================================
check_fail2ban() {
    if ! rc-service fail2ban status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}Fail2Ban 未运行，正在启动...${RESET}"
        rc-update add fail2ban default
        rc-service fail2ban start
        sleep 1
    fi
}

install_fail2ban() {
    echo -e "${GREEN}正在 Alpine 上安装 Fail2Ban...${RESET}"
    apk update
    # 确保防火墙和基础组件就绪
    apk add fail2ban curl wget iptables ip6tables
    
    rc-update add fail2ban default
    rc-service fail2ban start
    sleep 1
}

update_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${RED}Fail2Ban 未安装，无法更新，请先选择选项 1 进行安装${RESET}"
        return
    fi
    
    echo -e "${GREEN}正在更新 Fail2Ban...${RESET}"
    apk update
    apk add --upgrade fail2ban
    
    rc-service fail2ban restart
    echo -e "${GREEN}Fail2Ban 更新并重启完成${RESET}"
}

# 核心修改：为 Alpine Linux 专门定制生成的防御配置
configure_ssh() {
    # Alpine 的标准日志路径
    LOG_PATH="/var/log/messages"

    echo -ne "${GREEN}请输入 SSH 端口（默认22）: ${RESET}"
    read -r SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    echo -ne "${GREEN}请输入最大失败尝试次数 maxretry（默认5）: ${RESET}"
    read -r MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}

    echo -ne "${GREEN}请输入封禁时间 bantime(秒，默认600) : ${RESET}"
    read -r BAN_TIME
    BAN_TIME=${BAN_TIME:-600}

    # 创建专属配置目录
    mkdir -p /etc/fail2ban/jail.d

    # 专门为 Alpine 优化的本地配置
    # 1. 明确使用 iptables 动作（Alpine 经典后端）
    # 2. 指定 logpath 为 Alpine 的通用消息日志
    # 3. 针对 Alpine 的 OpenSSH / Dropbear 后端设置基础检测
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
backend = polling
logpath = $LOG_PATH
maxretry = $MAX_RETRY
bantime  = $BAN_TIME
banaction = iptables-multiport
purpleaction = 
EOF

    echo -e "${GREEN}正在应用专属配置并重启服务...${RESET}"
    rc-service fail2ban restart
    sleep 1
    echo -e "${GREEN}Alpine 专属 SSH 防暴力破解配置完成！${RESET}"
}

uninstall_fail2ban() {
    echo -e "${GREEN}正在卸载 Fail2Ban...${RESET}"
    rc-service fail2ban stop || true
    rc-update del fail2ban default || true
    rm -f /etc/fail2ban/jail.d/sshd.local
    apk del fail2ban
    echo -e "${GREEN}Fail2Ban 已从系统完全卸载${RESET}"
}

# =========================================================
# Fail2Ban 管理面板 (Alpine 专属风格)
# =========================================================
fail2ban_menu() {
    while true; do
        get_fail2ban_status

        clear
        echo -e "${GREEN}===============================${RESET}"
        echo -e "${GREEN} ◈   SSH 防暴力破解管理面板  ◈ ${RESET}"
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
        echo -e "${GREEN}  0. 退出面板${RESET}"
        echo -e "${GREEN}===============================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        
        read -r choice </dev/tty

        case $choice in
            1)
                if ! command -v fail2ban-client >/dev/null 2>&1; then
                    install_fail2ban
                else
                    rc-update add fail2ban default
                    rc-service fail2ban start
                fi
                configure_ssh
                ;;
            2)
                check_fail2ban
                if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
                    sed -i '/enabled/s/true/false/' /etc/fail2ban/jail.d/sshd.local
                    rc-service fail2ban restart
                    sleep 1
                    echo -e "${GREEN}SSH 防暴力破解已关闭${RESET}"
                else
                    echo -e "${RED}SSH 配置文件不存在，请先安装并开启 SSH 防护${RESET}"
                fi
                echo -ne "${GREEN}按回车返回菜单...${RESET}"; read -r
                ;;
            3)
                check_fail2ban
                if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
                    configure_ssh
                else
                    echo -e "${RED}SSH 配置文件不存在，请先安装并开启 SSH 防护${RESET}"
                fi
                echo -ne "${GREEN}按回车返回菜单...${RESET}"; read -r
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
                echo -ne "${GREEN}按回车返回菜单...${RESET}"; read -r
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
                echo -ne "${GREEN}按回车返回菜单...${RESET}"; read -r
                ;;
            6)
                check_fail2ban
                echo -e "${GREEN}进入日志实时监控，按 Ctrl+C 返回菜单${RESET}"
                trap 'echo -e "\n${GREEN}已退出日志监控，返回菜单${RESET}"' INT
                tail -n 20 -f /var/log/fail2ban.log || true
                trap - INT
                echo -ne "${GREEN}按回车继续...${RESET}"; read -r
                ;;
            7)
                uninstall_fail2ban
                break
                ;;
            11)
                update_fail2ban
                echo -ne "${GREEN}按回车返回菜单...${RESET}"; read -r
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
