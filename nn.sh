#!/bin/bash
# =========================================================
# DDNS 自动化管理面板（全面适配 Alpine / Ubuntu / Debian）
# =========================================================

# 视觉色彩定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 全局环境常量
SCRIPT_PATH="/usr/bin/ddns"
CONFIG_DIR="/etc/DDNS"
CONFIG_FILE="/etc/DDNS/.config"
CORE_SCRIPT="/etc/DDNS/DDNS"

# 优雅载入配置
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# =========================================================
# 基础环境检查与依赖修复
# =========================================================
check_environment() {
    # 1. 检查系统支持
    if ! grep -qiE "debian|ubuntu|alpine" /etc/os-release; then
        echo -e "${RED}错误: 本脚本仅支持 Debian、Ubuntu 或 Alpine 系统！${RESET}"
        exit 1
    fi

    # 2. 检查 Root 权限
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 请以 root 身份执行该脚本！${RESET}"
        exit 1
    fi

    # 3. 动态安装缺失依赖
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl，正在自动部署...${RESET}"
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y curl
        elif command -v apk >/dev/null 2>&1; then
            apk update && apk add curl
        fi
    fi

    # 4. Alpine 专属扩展环境补丁
    if grep -qiE "alpine" /etc/os-release; then
        if ! grep --version 2>/dev/null | grep -q "GNU"; then
            echo -e "${YELLOW}检测到 Alpine 环境，正在为其升级 GNU grep 以获得高阶正则支持...${RESET}"
            apk update && apk add grep
        fi
    fi
}

# =========================================================
# 动态获取系统与定时器状态
# =========================================================
get_system_status() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # 1. 检查安装状态
    if [ ! -f "$CONFIG_FILE" ] || [ "$Email" = "your_email@gmail.com" ] || [ -z "$Email" ]; then
        INSTALL_STATUS="${RED}未安装 / 未初始化${RESET}"
        DDNS_STATUS="${RED}已停止${RESET}"
        TG_STATUS="未配置"
        SHOW_V4_DOMAINS="未配置"
        SHOW_V6_DOMAINS="未开启"
        return
    else
        INSTALL_STATUS="${GREEN}已安装并初始化${RESET}"
    fi

    # 2. 检查 TG 状态
    if [ -n "$Telegram_Bot_Token" ] && [ -n "$Telegram_Chat_ID" ]; then
        TG_STATUS="${YELLOW}已配置${RESET}"
    else
        TG_STATUS="未配置"
    fi

    # 3. 检查 DDNS 守护状态
    if grep -qiE "alpine" /etc/os-release; then
        if crontab -l 2>/dev/null | grep -q "$CORE_SCRIPT"; then
            DDNS_STATUS="${YELLOW}运行中 (Cron)${RESET}"
        else
            DDNS_STATUS="${RED}已停止${RESET}"
        fi
    else
        if systemctl is-active --quiet ddns.timer 2>/dev/null; then
            DDNS_STATUS="${YELLOW}运行中 (Systemd)${RESET}"
        else
            DDNS_STATUS="${RED}已停止${RESET}"
        fi
    fi

    # 4. 格式化解析当前配置的域名显示
    if [ -n "${Domains[*]}" ] && [ "${Domains[0]}" != "your_domain1.com" ]; then
        SHOW_V4_DOMAINS="${YELLOW}${Domains[*]}${RESET}"
    else
        SHOW_V4_DOMAINS="未配置"
    fi

    if [ "$ipv6_set" = "true" ] && [ -n "${Domainsv6[*]}" ] && [ "${Domainsv6[0]}" != "your_domainv6_1.com" ]; then
        SHOW_V6_DOMAINS="${YELLOW}${Domainsv6[*]}${RESET}"
    else
        SHOW_V6_DOMAINS="未开启"
    fi
}

# =========================================================
# 核心组件写入与维护模块
# =========================================================
install_ddns_core() {
    mkdir -p "$CONFIG_DIR"

    # 如果主执行软链接不存在，则将自身复制进去作为快捷指令
    if [ ! -s "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    # 动态写入后台常驻 DDNS 核心逻辑
    cat <<'EOF' > "$CORE_SCRIPT"
#!/bin/bash
source /etc/DDNS/.config

# 修复关键 Bug：核心同步脚本必须在每次运行时动态获取当前公网 IP
Public_IPv4=$(curl -s4 --max-time 5 ip.sb || curl -s4 --max-time 5 api.ipify.org || true)
Public_IPv6=$(curl -s6 --max-time 5 ip.sb || curl -s6 --max-time 5 api64.ipify.org || true)

# IPv4 同步逻辑
if [ -n "$Public_IPv4" ] && [ "$Public_IPv4" != "$Old_Public_IPv4" ]; then
    for Domain in "${Domains[@]}"; do
        Zone_id=""
        current_domain="$Domain"
        while [[ "$current_domain" == *.* ]]; do
            Zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$current_domain" \
                 -H "X-Auth-Email: $Email" \
                 -H "X-Auth-Key: $Api_key" \
                 -H "Content-Type: application/json" \
                 | grep -Po '(?<="id":")[^"]*' | head -1)
            [ -n "$Zone_id" ] && break
            current_domain=${current_domain#*.}
        done

        if [ -z "$Zone_id" ]; then continue; fi

        DNS_IDv4=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=A&name=$Domain" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             | grep -Po '(?<="id":")[^"]*' | head -1)

        if [ -n "$DNS_IDv4" ]; then
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv4" \
                 -H "X-Auth-Email: $Email" \
                 -H "X-Auth-Key: $Api_key" \
                 -H "Content-Type: application/json" \
                 --data "{\"type\":\"A\",\"name\":\"$Domain\",\"content\":\"$Public_IPv4\"}" >/dev/null 2>&1
        fi
    done
fi

# IPv6 同步逻辑
if [ "$ipv6_set" = "true" ] && [ -n "$Public_IPv6" ] && [ "$Public_IPv6" != "$Old_Public_IPv6" ]; then
    for Domainv6 in "${Domainsv6[@]}"; do
        Zone_idv6=""
        current_domainv6="$Domainv6"
        while [[ "$current_domainv6" == *.* ]]; do
            Zone_idv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$current_domainv6" \
                 -H "X-Auth-Email: $Email" \
                 -H "X-Auth-Key: $Api_key" \
                 -H "Content-Type: application/json" \
                 | grep -Po '(?<="id":")[^"]*' | head -1)
            [ -n "$Zone_idv6" ] && break
            current_domainv6=${current_domainv6#*.}
        done

        if [ -z "$Zone_idv6" ]; then continue; fi

        DNS_IDv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records?type=AAAA&name=$Domainv6" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             | grep -Po '(?<="id":")[^"]*' | head -1)

        if [ -n "$DNS_IDv6" ]; then
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records/$DNS_IDv6" \
                 -H "X-Auth-Email: $Email" \
                 -H "X-Auth-Key: $Api_key" \
                 -H "Content-Type: application/json" \
                 --data "{\"type\":\"AAAA\",\"name\":\"$Domainv6\",\"content\":\"$Public_IPv6\"}" >/dev/null 2>&1
        fi
    done
fi

# Telegram 通知函数
send_telegram_notification() {
    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
    local message=$'🚀 <b>Cloudflare DDNS IP 变动提示</b>\n\n'
    if [[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]]; then
        message+=$'📌 <b>IPv4 域名</b>\n'
        for domain in "${Domains[@]}"; do message+="<code>${domain}</code>"$'\n'; done
        message+="🔄 <b>最新 IPv4:</b> <code>${Public_IPv4}</code>"$'\n\n'
    fi
    if [[ "$ipv6_set" == "true" && -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]]; then
        message+=$'📌 <b>IPv6 域名</b>\n'
        for domainv6 in "${Domainsv6[@]}"; do message+="<code>${domainv6}</code>"$'\n'; done
        message+="🔄 <b>最新 IPv6:</b> <code>${Public_IPv6}</code>"$'\n\n'
    fi
    message+="⏰ <b>检查时间:</b> ${current_time}"
    curl -s --max-time 15 -X POST "https://api.telegram.org/bot${Telegram_Bot_Token}/sendMessage" \
        --data-urlencode "chat_id=${Telegram_Chat_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${message}" >/dev/null 2>&1
}

# 触发通知与缓存更新
if [[ -n "$Telegram_Bot_Token" && -n "$Telegram_Chat_ID" && ( ("$Public_IPv4" != "$Old_Public_IPv4" && -n "$Public_IPv4") || ("$Public_IPv6" != "$Old_Public_IPv6" && -n "$Public_IPv6") ) ]]; then
    send_telegram_notification
fi

sleep 3
[[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]] && sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" /etc/DDNS/.config
[[ -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]] && sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" /etc/DDNS/.config
EOF

    # 初始化空白配置文件（只有在文件完全不存在时才建立占位符）
    if [ ! -f "$CONFIG_FILE" ]; then
        cat <<'EOF' > "$CONFIG_FILE"
Domains=("your_domain1.com")
ipv6_set="false"
Domainsv6=("your_domainv6_1.com")
Email="your_email@gmail.com"
Api_key="your_api_key"
Telegram_Bot_Token=""
Telegram_Chat_ID=""
Public_IPv4=""
Public_IPv6=""
Old_Public_IPv4=""
Old_Public_IPv6=""
EOF
    fi

    chmod +x "$CORE_SCRIPT"
}

# =========================================================
# 一键交互安装引导流程
# =========================================================
interactive_installation() {
    echo -e "${YELLOW}=== 开始进入 Cloudflare DDNS 交互安装向导 ===${RESET}"
    install_ddns_core
    set_cloudflare_api || return 1
    set_domain
    set_telegram_settings
    run_ddns
    echo -e "${GREEN}=== DDNS 系统安装并初始化成功！===${RESET}"
}

# =========================================================
# DDNS 策略调度器管理（Systemd 与 Alpine Cron 自适应切换）
# =========================================================
run_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        crontab -l 2>/dev/null | grep -v "$CORE_SCRIPT" > /tmp/cron.tmp || true
        echo "*/2 * * * * bash $CORE_SCRIPT >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
        echo -e "${GREEN}DDNS 计划任务已挂载至 Alpine Cron，每 2 分钟执行一次！${RESET}"
    else
        cat <<'EOF' > /etc/systemd/system/ddns.service
[Unit]
Description=ddns daemon service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/DDNS/DDNS

[Install]
WantedBy=multi-user.target
EOF

        cat <<'EOF' > /etc/systemd/system/ddns.timer
[Unit]
Description=ddns automation timer

[Timer]
OnUnitActiveSec=60s
Unit=ddns.service

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ddns.timer >/dev/null 2>&1
        echo -e "${GREEN}DDNS 自动化 Systemd 计时器创建成功，每 1 分钟执行一次！${RESET}"
    fi
}

set_ddns_run_interval() {
    read -rp "请输入新的 DDNS 运行检查间隔（单值/分钟）：" interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入不合法，必须为整数数字！${RESET}"
        return 1
    fi

    if grep -qiE "alpine" /etc/os-release; then
        crontab -l 2>/dev/null | grep -v "$CORE_SCRIPT" > /tmp/cron.tmp || true
        echo "*/$interval * * * * bash $CORE_SCRIPT >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp && rm -f /tmp/cron.tmp
    else
        sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=${interval}m/" /etc/systemd/system/ddns.timer
        systemctl daemon-reload && systemctl restart ddns.timer
    fi
    echo -e "${GREEN}执行周期已变更为每 ${interval} 分钟安全校验一次！${RESET}"
}

restart_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        run_ddns
    else
        systemctl restart ddns.timer >/dev/null 2>&1
    fi
    echo -e "${GREEN}DDNS 策略调度器已被重新激活！${RESET}"
}

stop_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        crontab -l 2>/dev/null | grep -v "$CORE_SCRIPT" | crontab -
    else
        systemctl stop ddns.service ddns.timer >/dev/null 2>&1
    fi
    echo -e "${YELLOW}DDNS 定时监控轮询已全面暂停。${RESET}"
}

# =========================================================
# 参数配置交互逻辑
# =========================================================
set_cloudflare_api() {
    echo -e "${YELLOW}=== 开始配置 CloudFlare API 凭据 ===${RESET}"
    read -rp "请输入您的 Cloudflare 账号邮箱: " EMail
    [ -z "$EMail" ] && { echo -e "${RED}输入取消${RESET}"; return 1; }
    read -rp "请输入您的 Global API Key 密钥: " Api_Key
    [ -z "$Api_Key" ] && { echo -e "${RED}输入取消${RESET}"; return 1; }

    sed -i "s|^Email=.*|Email=\"${EMail}\"|g" "$CONFIG_FILE"
    sed -i "s|^Api_key=.*|Api_key=\"${Api_Key}\"|g" "$CONFIG_FILE"
    echo -e "${GREEN}API 凭据已被成功保存！${RESET}"
}

set_domain() {
    echo -e "${YELLOW}=== 配置需要解析的专属域名 ===${RESET}"
    # IPv4 处理
    ipv4_check=$(curl -s4 --max-time 3 ip.sb || true)
    if [ -n "$ipv4_check" ]; then
        echo -e "${GREEN}本机解析成功，当前出口 IPv4: $ipv4_check${RESET}"
        read -rp "请输入A记录域名（多域名用英文逗号分隔，留空不改）: " Domain_input
        if [ -n "$Domain_input" ]; then
            Domain_input="${Domain_input//，/,}"
            IFS=' ' read -ra arr <<< "${Domain_input//,/ }"
            local fmt=""
            for d in "${arr[@]}"; do fmt+="\"$d\" "; done
            sed -i "s|^Domains=.*|Domains=($fmt)|" "$CONFIG_FILE"
        fi
    fi

    # IPv6 处理
    ipv6_check=$(curl -s6 --max-time 3 ip.sb || true)
    if [ -n "$ipv6_check" ]; then
        echo -e "${GREEN}本机解析成功，当前出口 IPv6: $ipv6_check${RESET}"
        read -rp "是否需要开启专属 IPv6 (AAAA) 解析绑定？(y/n): " enable_ipv6
        if [[ "$enable_ipv6" =~ ^[Yy]$ ]]; then
            sed -i 's/^ipv6_set=.*/ipv6_set="true"/g' "$CONFIG_FILE"
            read -rp "请输入AAAA记录域名（多域名用逗号分隔）: " Domainv6_input
            if [ -n "$Domainv6_input" ]; then
                Domainv6_input="${Domainv6_input//，/,}"
                IFS=' ' read -ra arrv6 <<< "${Domainv6_input//,/ }"
                local fmtv6=""
                for d in "${arrv6[@]}"; do fmtv6+="\"$d\" "; done
                sed -i "s|^Domainsv6=.*|Domainsv6=($fmtv6)|" "$CONFIG_FILE"
            fi
        else
            sed -i 's/^ipv6_set=.*/ipv6_set="false"/g' "$CONFIG_FILE"
        fi
    fi
}

set_telegram_settings() {
    echo -e "${YELLOW}=== 联动配置 Telegram 即时通知 ===${RESET}"
    read -rp "请输入 Telegram Bot Token (留空跳过): " Token
    if [ -n "$Token" ]; then
        read -rp "请输入 Telegram Chat ID: " Chat_ID
        if [ -n "$Chat_ID" ]; then
            sed -i "s|^Telegram_Bot_Token=.*|Telegram_Bot_Token=\"${Token}\"|g" "$CONFIG_FILE"
            sed -i "s|^Telegram_Chat_ID=.*|Telegram_Chat_ID=\"${Chat_ID}\"|g" "$CONFIG_FILE"
            echo -e "${GREEN}Telegram 通讯渠道绑定完毕！${RESET}"
        fi
    fi
}

show_service_detail() {
    echo -e "${YELLOW}=== 当前配置运行明细面板 ===${RESET}"
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    echo -e " ⚡ IPv4 域名组  : ${GREEN}${Domains[*]}${RESET}"
    echo -e " ⚡ IPv6 解析同步: ${GREEN}${ipv6_set}${RESET}"
    if [ "$ipv6_set" = "true" ] filter; then
        echo -e " ⚡ IPv6 域名组  : ${GREEN}${Domainsv6[*]}${RESET}"
    fi
    echo -e " ⚡ 上次同步IP缓存: ${YELLOW}${Old_Public_IPv4:-无历史数据}${RESET}"
}

test_tg_notification() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    if [[ -z "$Telegram_Bot_Token" || -z "$Telegram_Chat_ID" ]]; then
        echo -e "${RED}错误：您尚未配置有效的 Telegram 通知通道，请先执行选项 6。${RESET}"
        return
    fi
    echo -e "${YELLOW}正在向远端骨干网发送测试数据包...${RESET}"
    local code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "text=🔔 恭喜！DDNS 调度面板测试消息发送成功，接口链路正常。")
    if [ "$code" -eq 200 ]; then
        echo -e "${GREEN}[验证成功] 请前去查收您的 Telegram 消息！${RESET}"
    else
        echo -e "${RED}[验证失败] 接口抛出状态码: $code，请检查密匙或节点阻断。${RESET}"
    fi
}

# =========================================================
# 主视觉菜单面板逻辑
# =========================================================
ddns_menu() {
    while true; do
        clear
        get_system_status
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}        ◈  DDNS 自动化管理面板  ◈      ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 面板安装状态 : ${INSTALL_STATUS}"
        echo -e "${GREEN} 策略调度状态 : ${DDNS_STATUS}"
        echo -e "${GREEN} TG 通知绑定  : ${TG_STATUS}"
        echo -e "${GREEN} IPv4 解析域名: ${SHOW_V4_DOMAINS}"
        echo -e "${GREEN} IPv6 解析域名: ${SHOW_V6_DOMAINS}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}  1. 一键安装 / 初始化整个 DDNS 环境${RESET}"
        echo -e "${GREEN} ------------------------------------- ${RESET}"
        echo -e "${GREEN}  2. 重启 / 启动 DDNS 调度器${RESET}"
        echo -e "${GREEN}  3. 停止 DDNS 轮询检查${RESET}"
        echo -e "${GREEN}  4. 干净卸载 DDNS 核心及调度服务${RESET}"
        echo -e "${GREEN} ------------------------------------- ${RESET}"
        echo -e "${GREEN}  5. 修改解析域名组${RESET}"
        echo -e "${GREEN}  6. 调整 Cloudflare API 凭据${RESET}"
        echo -e "${GREEN}  7. 调整 Telegram 通知参数${RESET}"
        echo -e "${GREEN}  8. 调整定时循环轮询周期${RESET}"
        echo -e "${GREEN}  9. 查看服务运行明细数据${RESET}"
        echo -e "${GREEN} 10. 测试 Telegram 通知通道${RESET}"
        echo -e "${GREEN}  0. 退出管理面板${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -ne "${GREEN} 请输入操作编号: ${RESET}"
        read -r choice

        case $choice in
            1) interactive_installation ;;
            2) restart_ddns ;;
            3) stop_ddns ;;
            4)
                stop_ddns
                rm -rf "$CONFIG_DIR" "$SCRIPT_PATH" /etc/systemd/system/ddns.*
                [ -d "/etc/systemd" ] && systemctl daemon-reload
                echo -e "${RED}DDNS 模块以及快捷指令已在系统中干净卸载！${RESET}"
                exit 0
                ;;
            5) set_domain && restart_ddns ;;
            6) set_cloudflare_api && restart_ddns ;;
            7) set_telegram_settings ;;
            8) set_ddns_run_interval ;;
            9) show_service_detail ;;
            10) test_tg_notification ;;
            0) exit 0 ;;
            *) echo -e "${RED}未知输入，请按对应序列数字键输入...${RESET}"; sleep 1; continue ;;
        esac

        echo -ne "\n${GREEN}处理完成，按回车键返回主菜单...${RESET}"
        read -r
    done
}

# =========================================================
# 面板引导总入口
# =========================================================
check_environment
# 秒开进入主面板（由用户在菜单中决定何时执行安装/初始化）
ddns_menu
