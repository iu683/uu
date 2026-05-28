#!/bin/bash

# 输出字体颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
GREEN_ground="\033[42;37m" # 全局绿色
RED_ground="\033[41;37m"   # 全局红色
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

cop_info(){
clear
echo -e "${GREEN}######################################
      DDNS 管理(快捷指令:ddns)        
######################################${NC}"
echo
}

# 检查系统是否为 Debian、Ubuntu 或 Alpine
if ! grep -qiE "debian|ubuntu|alpine" /etc/os-release; then
    echo -e "${RED}本脚本仅支持 Debian、Ubuntu 或 Alpine 系统，请在这些系统上运行。${NC}"
    exit 1
fi

# 检查是否为root用户
if [[ $(whoami) != "root" ]]; then
    echo -e "${Error}请以root身份执行该脚本！"
    exit 1
fi

# 检查是否安装 curl 和 GNU grep（仅 Alpine）
check_curl() {
    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装 curl...${NC}"
        if grep -qiE "debian|ubuntu" /etc/os-release; then
            apt update && apt install -y curl
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Debian/Ubuntu 上安装 curl 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        elif grep -qiE "alpine" /etc/os-release; then
            apk update && apk add curl
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Alpine 上安装 curl 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        fi
    fi

    if grep -qiE "alpine" /etc/os-release; then
        if ! grep --version 2>/dev/null | grep -q "GNU"; then
            echo -e "${YELLOW}当前 grep 不是 GNU 版本，正在安装 GNU grep...${NC}"
            apk update && apk add grep
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Alpine 上安装 GNU grep 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        fi
    fi
}

# 返回菜单公共函数
back_to_menu() {
    echo
    read -rp "按回车键返回菜单..."
}

# 开始安装DDNS
install_ddns(){
    if [ ! -f "/usr/bin/ddns" ]; then
        curl -o /usr/bin/ddns https://raw.githubusercontent.com/iu683/uu/main/aa.sh && chmod +x /usr/bin/ddns
    fi
    mkdir -p /etc/DDNS
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash

source /etc/DDNS/.config

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

    if [ -z "$Zone_id" ]; then
        echo "无法获取域名 $Domain 的 Zone ID，跳过。"
        continue
    fi

    DNS_IDv4=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=A&name=$Domain" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         | grep -Po '(?<="id":")[^"]*' | head -1)

    if [ -n "$DNS_IDv4" ] && [ -n "$Public_IPv4" ] && [ "$Public_IPv4" != "$Old_Public_IPv4" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv4" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$Domain\",\"content\":\"$Public_IPv4\"}" >/dev/null 2>&1
    fi
done

if [ "$ipv6_set" = "true" ]; then
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

        if [ -z "$Zone_idv6" ]; then
            echo "无法获取域名 $Domainv6 的 Zone ID，跳过。"
            continue
        fi

        DNS_IDv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records?type=AAAA&name=$Domainv6" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             | grep -Po '(?<="id":")[^"]*' | head -1)

        if [ -n "$DNS_IDv6" ] && [ -n "$Public_IPv6" ] && [ "$Public_IPv6" != "$Old_Public_IPv6" ]; then
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records/$DNS_IDv6" \
                 -H "X-Auth-Email: $Email" \
                 -H "X-Auth-Key: $Api_key" \
                 -H "Content-Type: application/json" \
                 --data "{\"type\":\"AAAA\",\"name\":\"$Domainv6\",\"content\":\"$Public_IPv6\"}" >/dev/null 2>&1
        fi
    done
fi

send_telegram_notification() {
    # 格式化当前时间
    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 组装消息头部
    local message="🚀 <b>Cloudflare DDNS 动态公网 IP 变动提示</b>\n\n"

    # IPv4 部分
    if [[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]]; then
        message+="📌 <b>[IPv4 域名解析更新]</b>\n"
        local count=${#Domains[@]}
        for ((i=0; i<count; i++)); do
            if [ $i -eq $((count-1)) ]; then
                message+=" └─ <code>${Domains[i]}</code>\n"
            else
                message+=" ├─ <code>${Domains[i]}</code>\n"
            fi
        done
        message+=" ⚡ 🔄 <b>$Public_IPv4</b>\n\n"
    fi

    # IPv6 部分
    if [[ "$ipv6_set" == "true" && -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]]; then
        message+="📌 <b>[IPv6 域名解析更新]</b>\n"
        local countv6=${#Domainsv6[@]}
        for ((i=0; i<countv6; i++)); do
            if [ $i -eq $((countv6-1)) ]; then
                message+=" └─ <code>${Domainsv6[i]}</code>\n"
            else
                message+=" ├─ <code>${Domainsv6[i]}</code>\n"
            fi
        done
        message+=" ⚡ 🔄 <b>$Public_IPv6</b>\n\n"
    fi

    # 消息尾部
    message+="⏰ <b>检查时间:</b> $current_time"

    # 发送请求
    curl -s -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "parse_mode=HTML" \
        -d "text=$message"
}

if [[ -n "$Telegram_Bot_Token" && -n "$Telegram_Chat_ID" && ( ("$Public_IPv4" != "$Old_Public_IPv4" && -n "$Public_IPv4") || ("$Public_IPv6" != "$Old_Public_IPv6" && -n "$Public_IPv6") ) ]]; then
    send_telegram_notification
fi

sleep 3

if [[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]]; then
    sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" /etc/DDNS/.config
fi

if [[ -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]]; then
    sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" /etc/DDNS/.config
fi
EOF

    cat <<'EOF' > /etc/DDNS/.config
Domains=("your_domain1.com" "your_domain2.com")
ipv6_set="false"
Domainsv6=("your_domainv6_1.com" "your_domainv6_2.com")
Email="your_email@gmail.com"
Api_key="your_api_key"
Telegram_Bot_Token=""
Telegram_Chat_ID=""

regex_pattern='^(eth|ens|eno|esp|enp)[0-9]+'
InterFace=($(ip link show | awk -F': ' '{print $2}' | grep -E "$regex_pattern" | sed "s/@.*//g"))

Public_IPv4=""
Public_IPv6=""
Old_Public_IPv4=""
Old_Public_IPv6=""
ipv4Regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
ipv6Regex="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"

if grep -qiE "debian|ubuntu" /etc/os-release; then
    for i in "${InterFace[@]}"; do
        ipv4=$(curl -s4 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
        if [[ -z "$ipv4" ]]; then
            ipv4=$(curl -s4 --max-time 3 --interface "$i" https://api.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
        fi
        if [[ -n "$ipv4" && "$ipv4" =~ $ipv4Regex ]]; then
            Public_IPv4="$ipv4"
            break # 修复 Bug：获取到有效 IP 后直接跳出，防止被后续空接口覆盖
        fi
    done

    for i in "${InterFace[@]}"; do
        if [[ "$ipv6_set" == "true" ]]; then
            ipv6=$(curl -s6 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
            if [[ -z "$ipv6" ]]; then
                ipv6=$(curl -s6 --max-time 3 --interface "$i" https://api6.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
            fi
            if [[ -n "$ipv6" && "$ipv6" =~ $ipv6Regex ]]; then
                Public_IPv6="$ipv6"
                break # 同上
            fi
        fi
    done
else
    ipv4=$(curl -s4 --max-time 3 ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
    if [[ -z "$ipv4" ]]; then
        ipv4=$(curl -s4 --max-time 3 https://api.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
    fi
    if [[ -n "$ipv4" && "$ipv4" =~ $ipv4Regex ]]; then
        Public_IPv4="$ipv4"
    fi

    if [[ "$ipv6_set" == "true" ]]; then
        ipv6=$(curl -s6 --max-time 3 ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
        if [[ -z "$ipv6" ]]; then
            ipv6=$(curl -s6 --max-time 3 https://api6.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
        fi
        if [[ -n "$ipv6" && "$ipv6" =~ $ipv6Regex ]]; then
            Public_IPv6="$ipv6"
        fi
    fi
fi
EOF
    chmod +x /etc/DDNS/DDNS && chmod +x /etc/DDNS/.config
    echo -e "${Info}DDNS 安装完成！"
    echo
}

# 检查 DDNS 状态
check_ddns_status() {
    if grep -qiE "alpine" /etc/os-release; then
        if crontab -l | grep -q "/etc/DDNS/DDNS"; then
            ddns_status="running"
        else
            ddns_status="dead"
        fi
    else
        if [[ -f "/etc/systemd/system/ddns.timer" ]]; then
            STatus=$(systemctl status ddns.timer | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
            if [[ $STatus =~ "waiting" || $STatus =~ "running" ]]; then
                ddns_status="running"
            else
                ddns_status="dead"
            fi
        else
            ddns_status="not_installed"
        fi
    fi
}

# 后续操作菜单循环
go_ahead(){
    while true; do
        cop_info
        check_ddns_status
        if [[ "$ddns_status" == "running" ]]; then
            echo -e "${Info}DDNS状态：${GREEN}已安装${NC} 并 ${GREEN}已启动${NC}"
        else
            echo -e "${Tip}DDNS状态：${GREEN}已安装${NC} 但 ${RED}未启动${NC}"
        fi
        echo
        echo -e "${Tip}选择一个选项：
  ${GREEN}1${NC}：重启 DDNS
  ${GREEN}2${NC}：停止 DDNS
  ${GREEN}3${NC}：卸载 DDNS
  ${GREEN}4${NC}：修改要解析的域名
  ${GREEN}5${NC}：修改 Cloudflare Api
  ${GREEN}6${NC}：配置 Telegram 通知
  ${GREEN}7${NC}：更改 DDNS 运行时间
  ${GREEN}8${NC}：查看服务运行状态
  ${GREEN}9${NC}：测试 Telegram 通知
  ${GREEN}0${NC}：退出" 
        echo
        read -p "选项: " option
        if [[ ! "$option" =~ ^[0-9]$ ]]; then
            echo -e "${Error}请输入正确的数字 [0-9]"
            sleep 1
            continue
        fi
        
        case "$option" in
            0)
                exit 0
            ;;
            1)
                restart_ddns
                back_to_menu
            ;;
            2)
                stop_ddns
                back_to_menu
            ;;
            3)
                if grep -qiE "alpine" /etc/os-release; then
                    stop_ddns
                    rm -rf /etc/DDNS /usr/bin/ddns
                else
                    systemctl stop ddns.service >/dev/null 2>&1
                    systemctl stop ddns.timer >/dev/null 2>&1
                    rm -rf /etc/systemd/system/ddns.service /etc/systemd/system/ddns.timer /etc/DDNS /usr/bin/ddns
                fi
                echo -e "${Info}DDNS 已卸载！"
                exit 0
            ;;
            4)
                set_domain
                restart_ddns
                back_to_menu
            ;;
            5)
                set_cloudflare_api
                restart_ddns
                back_to_menu
            ;;
            6)
                set_telegram_settings
                back_to_menu
            ;;
            7)
                set_ddns_run_interval
                back_to_menu
            ;;
            8)
                show_service_detail
                back_to_menu
            ;;
            9)
                test_tg_notification
                back_to_menu
            ;;
        esac
    done
}

# 设置Cloudflare Api
set_cloudflare_api(){
    echo -e "${Tip}开始配置CloudFlare API..."
    echo
    read -rp "请输入您的Cloudflare邮箱: " EMail
    if [ -z "$EMail" ]; then
        echo -e "${Error}未输入邮箱，操作取消。"
        return 1
    fi
    echo -e "${Info}你的邮箱：${RED_ground}${EMail}${NC}"
    echo

    read -rp "请输入您的Cloudflare(Global API Key)密钥: " Api_Key
    if [ -z "$Api_Key" ]; then
        echo -e "${Error}未输入密钥，操作取消。"
        return 1
    fi
    echo -e "${Info}你的密钥：${RED_ground}${Api_Key}${NC}"
    echo

    sed -i "s|^Email=.*|Email=\"${EMail}\"|g" /etc/DDNS/.config
    sed -i "s|^Api_key=.*|Api_key=\"${Api_Key}\"|g" /etc/DDNS/.config
}


# 设置解析的域名
set_domain() {
    ipv4_check=$(curl -s -4 ip.sb || true)
    if [ -n "$ipv4_check" ]; then
        echo -e "${Info}检测到IPv4地址: ${ipv4_check}"
        read -rp "请输入IPv4域名（例如:v4.888.xyz，回车跳过）: " Domain_input
        if [ -n "$Domain_input" ]; then
            Domain_input="${Domain_input//，/,}"
            IFS=',' read -ra Domains_arr <<< "$Domain_input"
            # 格式化写回配置数组
            local formatted_domains=""
            for d in "${Domains_arr[@]}"; do formatted_domains+="\"$d\" "; done
            sed -i "s|^Domains=.*|Domains=($formatted_domains)|" /etc/DDNS/.config
            echo -e "${Info}已保存IPv4域名: ${RED_ground}${Domains_arr[*]}${NC}"
        fi
    fi

    ipv6_check=$(curl -s -6 ip.sb || true)
    if [ -n "$ipv6_check" ]; then
        echo -e "${Info}检测到IPv6地址: ${ipv6_check}"
        read -rp "是否开启 IPv6 解析？(y/n): " enable_ipv6
        if [[ "$enable_ipv6" =~ ^[Yy]$ ]]; then
            sed -i 's/^ipv6_set=.*/ipv6_set="true"/g' /etc/DDNS/.config
            read -rp "请输入IPv6域名（例如:v6.888.xyz，回车跳过）: " Domainv6_input
            if [ -n "$Domainv6_input" ]; then
                Domainv6_input="${Domainv6_input//，/,}"
                IFS=',' read -ra Domainsv6_arr <<< "$Domainv6_input"
                local formatted_domains_v6="" 
                for d in "${Domainsv6_arr[@]}"; do formatted_domains_v6+="\"$d\" "; done 
                sed -i "s|^Domainsv6=.*|Domainsv6=($formatted_domains_v6)|" /etc/DDNS/.config
                echo -e "${Info}已保存IPv6域名: ${RED_ground}${Domainsv6_arr[*]}${NC}"
            fi
        else
            sed -i 's/^ipv6_set=.*/ipv6_set="false"/g' /etc/DDNS/.config
        fi
    fi
}
# 设置Telegram参数
set_telegram_settings(){
    echo -e "${Info}开始配置Telegram通知设置..."
    read -rp "请输入您的Telegram Bot Token (回车跳过): " Token
    if [ -n "$Token" ]; then
        read -rp "请输入您的Telegram Chat ID (回车跳过): " Chat_ID
        if [ -n "$Chat_ID" ]; then
            sed -i "s|^Telegram_Bot_Token=.*|Telegram_Bot_Token=\"${Token}\"|g" /etc/DDNS/.config
            sed -i "s|^Telegram_Chat_ID=.*|Telegram_Chat_ID=\"${Chat_ID}\"|g" /etc/DDNS/.config
            echo -e "${Info}Telegram 通知配置成功！"
        fi
    fi
}

# 运行DDNS服务
run_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        if ! crontab -l | grep -q "/etc/DDNS/DDNS"; then
            (crontab -l 2>/dev/null; echo "*/2 * * * * /bin/bash /etc/DDNS/DDNS >/dev/null 2>&1") | crontab -
            echo -e "${Info}ddns 脚本已挂载至 Cron，每 2 分钟运行一次！"
        fi
    else
        service='[Unit]
Description=ddns
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/DDNS
ExecStart=bash DDNS

[Install]
WantedBy=multi-user.target'

        timer='[Unit]
Description=ddns timer

[Timer]
OnUnitActiveSec=60s
Unit=ddns.service

[Install]
WantedBy=multi-user.target'

        if [ ! -f "/etc/systemd/system/ddns.service" ]; then
            echo "$service" >/etc/systemd/system/ddns.service
            echo "$timer" >/etc/systemd/system/ddns.timer
            systemctl daemon-reload
            systemctl enable --now ddns.timer >/dev/null 2>&1
            echo -e "${Info}ddns 定时任务已创建，每 1 分钟执行一次！"
        fi
    fi
}

# 更改运行时间间隔
set_ddns_run_interval() {
    read -rp "请输入新的 DDNS 运行间隔（分钟）： " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo -e "${Error}无效输入！"
        return 1
    fi

    if grep -qiE "alpine" /etc/os-release; then
        crontab -l | grep -v "/etc/DDNS/DDNS" | crontab -
        (crontab -l 2>/dev/null; echo "*/$interval * * * * /bin/bash /etc/DDNS/DDNS >/dev/null 2>&1") | crontab -
        echo -e "${Info}已变更为每 ${interval} 分钟运行一次！"
    else
        sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=${interval}m/" /etc/systemd/system/ddns.timer
        systemctl daemon-reload && systemctl restart ddns.timer
        echo -e "${Info}已变更为每 ${interval} 分钟运行一次！"
    fi
}

restart_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        if crontab -l | grep -q "/etc/DDNS/DDNS"; then
            echo -e "${Info}DDNS 已在计划任务中生效。"
        else
            run_ddns
        fi
    else
        systemctl restart ddns.service >/dev/null 2>&1
        systemctl restart ddns.timer >/dev/null 2>&1
        echo -e "${Info}DDNS 服务已重启！"
    fi
}

stop_ddns(){
    if grep -qiE "alpine" /etc/os-release; then
        crontab -l | grep -v "/etc/DDNS/DDNS" | crontab -
        echo -e "${Info}DDNS Cron 任务已停止！"
    else
        systemctl stop ddns.service >/dev/null 2>&1
        systemctl stop ddns.timer >/dev/null 2>&1
        echo -e "${Info}DDNS Systemd 服务已停止！"
    fi
}

show_service_detail() {
    echo -e "${Info}--- 当前配置与状态 ---"
    source /etc/DDNS/.config
    echo -e "IPv4 域名: ${YELLOW}${Domains[*]}${NC}"
    echo -e "IPv6 开启: ${YELLOW}${ipv6_set}${NC}"
    echo -e "最后记录 IP: ${YELLOW}${Old_Public_IPv4:-未记录}${NC}"
    
    if grep -qiE "alpine" /etc/os-release; then
        echo -en "Cron 任务: "
        if crontab -l | grep -q "/etc/DDNS/DDNS"; then
            echo -e "${GREEN}运行中${NC}"
            crontab -l | grep "/etc/DDNS/DDNS"
        else
            echo -e "${RED}未在计划任务中${NC}"
        fi
    else
        echo -en "Systemd 状态: "
        if systemctl is-active --quiet ddns.timer; then
            echo -e "${GREEN}运行中${NC}"
        else
            echo -e "${RED}已停止${NC}"
        fi
    fi
    echo
}

test_tg_notification() {
    source /etc/DDNS/.config
    if [[ -z "$Telegram_Bot_Token" || -z "$Telegram_Chat_ID" ]]; then
        echo -e "${Error} 未配置 Telegram，请先选择选项 6"
        return
    fi
    echo -e "${Info} 正在发送测试消息..."
    test_msg="🔔 DDNS 测试通知VPS: $(hostname)状态: 配置正常"
    
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "text=\"$test_msg\"")
    
    if [ "$status_code" -eq 200 ]; then
        echo -e "${GREEN}[成功]${NC} 请检查你的 Telegram 消息！"
    else
        echo -e "${Error} 发送失败，HTTP 状态码: $status_code"
    fi
}

# 检查引导函数
check_ddns_install(){
    if [ ! -f "/etc/DDNS/.config" ]; then
        cop_info
        echo -e "${Tip}DDNS 未安装，现在开始安装..."
        echo
        install_ddns
        set_cloudflare_api
        set_domain
        set_telegram_settings
        run_ddns
        echo -e "${Info}安装完成，现已进入管理菜单。"
        sleep 2
    fi
    go_ahead
}

# 执行入口
check_curl
check_ddns_install
