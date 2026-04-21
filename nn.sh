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
           DDNS 管理        
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

# 检查是否安装 curl 和 GNU grep（仅 Alpine），如果没有安装，则安装它们
check_curl() {
    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装 curl...${NC}"

        # 根据不同的系统类型选择安装命令
        if grep -qiE "debian|ubuntu" /etc/os-release; then
            apt update
            apt install -y curl
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Debian/Ubuntu 上安装 curl 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        elif grep -qiE "alpine" /etc/os-release; then
            apk update
            apk add curl
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Alpine 上安装 curl 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        fi
    fi

    # 仅在 Alpine 系统上检查是否为 GNU 版本的 grep，如果不是，则安装 GNU grep
    if grep -qiE "alpine" /etc/os-release; then
        if ! grep --version 2>/dev/null | grep -q "GNU"; then
            echo -e "${YELLOW}当前 grep 不是 GNU 版本，正在安装 GNU grep...${NC}"
            
            apk update
            apk add grep
            if [ $? -ne 0 ]; then
                echo -e "${RED}在 Alpine 上安装 GNU grep 失败，请手动安装后重新运行脚本。${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}GNU grep 已经安装。${NC}"
        fi
    fi
}

# 开始安装DDNS
install_ddns(){
    if [ ! -f "/usr/bin/ddns" ]; then
        curl -o /usr/bin/ddns https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh && chmod +x /usr/bin/ddns
    fi
    mkdir -p /etc/DDNS
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash

# 引入环境变量文件
source /etc/DDNS/.config

# 保存旧的 IP 地址
Old_Public_IPv4="$Old_Public_IPv4"
Old_Public_IPv6="$Old_Public_IPv6"

for Domain in "${Domains[@]}"; do
    # 获取根域名（假设是二级域名，截取主域名部分）
    Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')

    # 使用Cloudflare API获取根域名的区域ID
    Zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         | grep -Po '(?<="id":")[^"]*' | head -1)

    # 获取IPv4 DNS记录ID
    DNS_IDv4=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=A&name=$Domain" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         | grep -Po '(?<="id":")[^"]*' | head -1)

    # 更新IPv4 DNS记录
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv4" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$Domain\",\"content\":\"$Public_IPv4\"}" >/dev/null 2>&1
done

# -----------------------------
# 处理 IPv6 域名的 DNS 更新
# -----------------------------
if [ "$ipv6_set" = "true" ]; then
    for Domainv6 in "${Domainsv6[@]}"; do
        # 获取根域名（假设是二级域名，截取主域名部分）
        Root_domainv6=$(echo "$Domainv6" | awk -F '.' '{print $(NF-1)"."$NF}')

        # 使用Cloudflare API获取根域名的区域ID
        Zone_idv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domainv6" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             | grep -Po '(?<="id":")[^"]*' | head -1)

        # 获取IPv6 DNS记录ID
        DNS_IDv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records?type=AAAA&name=$Domainv6" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             | grep -Po '(?<="id":")[^"]*' | head -1)

        # 更新IPv6 DNS记录
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_idv6/dns_records/$DNS_IDv6" \
             -H "X-Auth-Email: $Email" \
             -H "X-Auth-Key: $Api_key" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"AAAA\",\"name\":\"$Domainv6\",\"content\":\"$Public_IPv6\"}" >/dev/null 2>&1
    done
fi

# 发送Telegram通知
if [[ -n "$Telegram_Bot_Token" && -n "$Telegram_Chat_ID" && (("$Public_IPv4" != "$Old_Public_IPv4" && -n "$Public_IPv4") || ("$Public_IPv6" != "$Old_Public_IPv6" && -n "$Public_IPv6")) ]]; then
    send_telegram_notification
fi

# 延迟3秒
sleep 3

# 保存当前的 IP 地址到配置文件，但只有当 IP 地址有变化时才进行更新
if [[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]]; then
    sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" /etc/DDNS/.config
fi

# 检查 IPv6 地址是否有效且发生变化
if [[ -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]]; then
    sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" /etc/DDNS/.config
fi
EOF
    cat <<'EOF' > /etc/DDNS/.config
# 多域名支持
Domains=("your_domain1.com" "your_domain2.com")     # 你要解析的IPv4域名数组
ipv6_set="setting"                                    # 开启 IPv6 解析
Domainsv6=("your_domainv6_1.com" "your_domainv6_2.com")  # 你要解析的IPv6域名数组
Email="your_email@gmail.com"                       # 你在 Cloudflare 注册的邮箱
Api_key="your_api_key"                             # 你的 Cloudflare API 密钥

# Telegram Bot Token 和 Chat ID
Telegram_Bot_Token=""
Telegram_Chat_ID=""

# 获取公网IP地址
regex_pattern='^(eth|ens|eno|esp|enp)[0-9]+'

# 获取网络接口列表
InterFace=($(ip link show | awk -F': ' '{print $2}' | grep -E "$regex_pattern" | sed "s/@.*//g"))

Public_IPv4=""
Public_IPv6=""
Old_Public_IPv4=""
Old_Public_IPv6=""
ipv4Regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
ipv6Regex="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"

# 检查操作系统类型
if grep -qiE "debian|ubuntu" /etc/os-release; then
    # Debian/Ubuntu系统的IP获取方法
    for i in "${InterFace[@]}"; do
        # 尝试通过第一个接口获取 IPv4 地址
        ipv4=$(curl -s4 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)

        # 如果第一个接口的 IPv4 地址获取失败，尝试备用接口
        if [[ -z "$ipv4" ]]; then
            ipv4=$(curl -s4 --max-time 3 --interface "$i" https://api.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
        fi

        # 验证获取到的 IPv4 地址是否是有效的 IP 地址
        if [[ -n "$ipv4" && "$ipv4" =~ $ipv4Regex ]]; then
            Public_IPv4="$ipv4"
        fi

        # 检查是否启用了 IPv6 解析
        if [[ "$ipv6_set" == "true" ]]; then
            # 尝试通过第一个接口获取 IPv6 地址
            ipv6=$(curl -s6 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)

            # 如果第一个接口的 IPv6 地址获取失败，尝试备用接口
            if [[ -z "$ipv6" ]]; then
                ipv6=$(curl -s6 --max-time 3 --interface "$i" https://api6.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
            fi

            # 验证获取到的 IPv6 地址是否是有效的 IP 地址
            if [[ -n "$ipv6" && "$ipv6" =~ $ipv6Regex ]]; then
                Public_IPv6="$ipv6"
            fi
        fi
    done
else
    # Alpine系统的IP获取方法
    # 尝试获取 IPv4 地址
    ipv4=$(curl -s4 --max-time 3 ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
    if [[ -z "$ipv4" ]]; then
        ipv4=$(curl -s4 --max-time 3 https://api.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
    fi

    # 验证获取到的 IPv4 地址是否是有效的 IP 地址
    if [[ -n "$ipv4" && "$ipv4" =~ $ipv4Regex ]]; then
        Public_IPv4="$ipv4"
    fi

    # 检查是否启用了 IPv6 解析
    if [[ "$ipv6_set" == "true" ]]; then
        # 尝试获取 IPv6 地址
        ipv6=$(curl -s6 --max-time 3 ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)
        if [[ -z "$ipv6" ]]; then
            ipv6=$(curl -s6 --max-time 3 https://api6.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
        fi

        # 验证获取到的 IPv6 地址是否是有效的 IP 地址
        if [[ -n "$ipv6" && "$ipv6" =~ $ipv6Regex ]]; then
            Public_IPv6="$ipv6"
        fi
    fi
fi

# 发送 Telegram 通知函数
send_telegram_notification() {
    local message=""

    # 遍历 Domains 数组，构建域名部分
    for domain in "${Domains[@]}"; do
        message+="$domain "
    done

    # 添加 IPv4 更新信息
    message+="IPv4更新 $Old_Public_IPv4 🔜 $Public_IPv4 。"

    # 如果 ipv6_set 为 true，则添加 IPv6 更新信息
    if [ "$ipv6_set" == "true" ]; then
        # 检查 Domains 和 Domainsv6 是否相同
        if [ "${Domains[*]}" != "${Domainsv6[*]}" ]; then
            # 遍历 Domainsv6 数组，构建 IPv6 域名部分
            for domainv6 in "${Domainsv6[@]}"; do
                message+="$domainv6 "
            done
        fi

        # 添加 IPv6 更新信息
        message+="IPv6更新 $Old_Public_IPv6 🔜 $Public_IPv6 。"
    fi

    # 发送通知
    curl -s -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "text=$message"
}

EOF
    chmod +x /etc/DDNS/DDNS && chmod +x /etc/DDNS/.config
    echo -e "${Info}DDNS 安装完成！"
    echo
}

# 检查 DDNS 状态
check_ddns_status() {
    if grep -qiE "alpine" /etc/os-release; then
        # 检查 cron 任务是否存在
        if crontab -l | grep -q "/bin/bash /etc/DDNS/DDNS"; then
            ddns_status=running
        else
            ddns_status=dead
        fi
    else
        # 在 Debian/Ubuntu 上检查 systemd timer 状态
        if [[ -f "/etc/systemd/system/ddns.timer" ]]; then
            STatus=$(systemctl status ddns.timer | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
            if [[ $STatus =~ "waiting" || $STatus =~ "running" ]]; then
                ddns_status=running
            else
                ddns_status=dead
            fi
        else
            ddns_status=not_installed
        fi
    fi
}

# 后续操作
go_ahead(){
    echo -e "${Tip}选择一个选项：
  ${GREEN}0${NC}：退出
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
    until [[ "$option" =~ ^[0-7]$ ]]; do  # 更新有效选项范围
        echo -e "${Error}请输入正确的数字 [0-7]"
        echo
        exit 1
    done
    case "$option" in
        0)
            exit 1
        ;;
        1)
            restart_ddns
        ;;
        2)
            stop_ddns
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
            echo
        ;;
        4)
            set_domain
            restart_ddns
            sleep 2
            check_ddns_install
        ;;
        5)
            set_cloudflare_api
            if grep -qiE "alpine" /etc/os-release; then
                restart_ddns
                sleep 2
            else
                if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
                    run_ddns
                    sleep 2
                else
                    restart_ddns
                    sleep 2
                fi
            fi
            check_ddns_install
        ;;
        6)
            set_telegram_settings
            check_ddns_install
        ;;
        7)
            set_ddns_run_interval  # 调用新函数以更改 DDNS 运行时间
            sleep 2
            check_ddns_install
        ;;
        8)
            show_service_detail
        ;;
        9)
            test_tg_notification
        ;;
    esac
}

# 设置Cloudflare Api
set_cloudflare_api(){
    echo -e "${Tip}开始配置CloudFlare API..."
    echo

    echo -e "${Tip}请输入您的Cloudflare邮箱"
    read -rp "邮箱: " EMail
    if [ -z "$EMail" ]; then
        echo -e "${Error}未输入邮箱，无法执行操作！"
        exit 1
    else
        EMAIL="$EMail"
    fi
    echo -e "${Info}你的邮箱：${RED_ground}${EMAIL}${NC}"
    echo

    echo -e "${Tip}请输入您的Cloudflare API密钥"
    read -rp "密钥: " Api_Key
    if [ -z "Api_Key" ]; then
        echo -e "${Error}未输入密钥，无法执行操作！"
        exit 1
    else
        API_KEY="$Api_Key"
    fi
    echo -e "${Info}你的密钥：${RED_ground}${API_KEY}${NC}"
    echo

    sed -i 's/^#\?Email=".*"/Email="'"${EMAIL}"'"/g' /etc/DDNS/.config
    sed -i 's/^#\?Api_key=".*"/Api_key="'"${API_KEY}"'"/g' /etc/DDNS/.config
}

# 设置解析的域名
set_domain() {
    # 检查是否有IPv4
    ipv4_check=$(curl -s ip.sb -4)
    if [ -n "$ipv4_check" ]; then
        echo -e "${Info}检测到IPv4地址: ${ipv4_check}"
        echo -e "${Tip}请输入您要解析的IPv4域名（可解析多个域名，使用逗号分隔） (或按回车跳过)"
        read -rp "IPv4域名: " Domain_input
        if [ -z "$Domain_input" ]; then
            echo -e "${Info}跳过IPv4域名设置。"
        else
            # 替换中文逗号为英文逗号
            Domain_input="${Domain_input//，/,}"
            IFS=',' read -ra Domains <<< "$Domain_input"
            echo -e "${Info}你输入的IPv4域名为: ${RED_ground}${Domains[*]}${NC}"
            echo
            # 更新 .config 文件中的 IPv4 域名数组，保持原位置修改
            sed -i '/^Domains=/c\Domains=('"${Domains[*]}"')' /etc/DDNS/.config
        fi
    else
        echo -e "${Info}未检测到IPv4地址，跳过IPv4域名设置。"
        echo
    fi

    # 检查是否有IPv6
    ipv6_check=$(curl -s ip.sb -6)
    if [ -n "$ipv6_check" ]; then
        echo -e "${Info}检测到IPv6地址: ${ipv6_check}"

        # 检查是否开启 IPv6 解析
        while true; do
            echo -e "${Tip}是否开启 IPv6 解析？(y/n)"
            read -rp "选择: " enable_ipv6

            if [[ "$enable_ipv6" =~ ^[Yy]$ ]]; then
                ipv6_set="true"
                # 更新 .config 文件中的 ipv6_set 为 true
                sed -i 's/^#\?ipv6_set=".*"/ipv6_set="true"/g' /etc/DDNS/.config

                echo -e "${Tip}请输入您要解析的IPv6域名（可解析多个域名，使用逗号分隔） (或按回车跳过)"
                read -rp "IPv6域名: " Domainv6_input

                if [ -z "$Domainv6_input" ]; then
                    echo -e "${Info}跳过IPv6域名设置。"
                    echo
                else
                    # 替换中文逗号为英文逗号
                    Domainv6_input="${Domainv6_input//，/,}"
                    IFS=',' read -ra Domainsv6 <<< "$Domainv6_input"
                    echo -e "${Info}你输入的IPv6域名为: ${RED_ground}${Domainsv6[*]}${NC}"
                    echo
                    # 更新 .config 文件中的 IPv6 域名数组，保持原位置修改
                    sed -i '/^Domainsv6=/c\Domainsv6=('"${Domainsv6[*]}"')' /etc/DDNS/.config
                fi
                break
            elif [[ "$enable_ipv6" =~ ^[Nn]$ ]]; then
                ipv6_set="false"
                # 更新 .config 文件中的 ipv6_set 为 false
                sed -i 's/^#\?ipv6_set=".*"/ipv6_set="false"/g' /etc/DDNS/.config
                echo -e "${Info}IPv6 解析未开启，跳过 IPv6 域名设置。"
                echo
                break
            else
                echo -e "${Error}无效输入，请输入 'y' 或 'n'。"
            fi
        done
    else
        echo -e "${Info}未检测到IPv6地址，跳过IPv6域名设置。"
        echo
        ipv6_set="false"
        # 更新 .config 文件中的 ipv6_set 为 false
        sed -i 's/^#\?ipv6_set=".*"/ipv6_set="false"/g' /etc/DDNS/.config
    fi
}

# 设置Telegram参数
set_telegram_settings(){
    echo -e "${Info}开始配置Telegram通知设置..."
    echo

    echo -e "${Tip}请输入您的Telegram Bot Token，如果不使用Telegram通知请直接按 Enter 跳过"
    read -rp "Token: " Token
    if [ -n "$Token" ]; then
        TELEGRAM_BOT_TOKEN="$Token"
        echo -e "${Info}你的TOKEN：${RED_ground}$TELEGRAM_BOT_TOKEN${NC}"
        echo

        echo -e "${Tip}请输入您的Telegram Chat ID，如果不使用Telegram通知请直接按 Enter 跳过"
        read -rp "Chat ID: " Chat_ID
        if [ -n "$Chat_ID" ]; then
            TELEGRAM_CHAT_ID="$Chat_ID"
            echo -e "${Info}你的Chat ID：${RED_ground}$TELEGRAM_CHAT_ID${NC}"
            echo

            sed -i 's/^#\?Telegram_Bot_Token=".*"/Telegram_Bot_Token="'"${TELEGRAM_BOT_TOKEN}"'"/g' /etc/DDNS/.config
            sed -i 's/^#\?Telegram_Chat_ID=".*"/Telegram_Chat_ID="'"${TELEGRAM_CHAT_ID}"'"/g' /etc/DDNS/.config
        else
            echo -e "${Info}已跳过设置Telegram Chat ID"
        fi
    else
        echo -e "${Info}已跳过设置Telegram Bot Token和Chat ID"
        echo
        return  # 如果没有输入 Token，则直接返回，跳过设置 Chat ID 的步骤
    fi
}

# 运行DDNS服务
run_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        # 在 Alpine Linux 上使用 cron
        echo -e "${Info}设置 ddns 脚本每两分钟运行一次..."

        # 检查 cron 任务是否已存在，防止重复添加
        if ! crontab -l | grep -q "/bin/bash /etc/DDNS/DDNS >/dev/null 2>&1"; then
            # 设置 cron 任务
            (crontab -l; echo "*/2 * * * * /bin/bash /etc/DDNS/DDNS >/dev/null 2>&1") | crontab -
            echo -e "${Info}ddns 脚本已设置为每两分钟运行一次！"
        else
            echo -e "${Tip}ddns 脚本的 cron 任务已存在，无需再次创建！"
        fi
    else
        # 在 Debian/Ubuntu 上使用 systemd
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

        if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
            echo -e "${Info}创建 ddns 定时任务..."
            echo "$service" >/etc/systemd/system/ddns.service
            echo "$timer" >/etc/systemd/system/ddns.timer
            echo -e "${Info}ddns 定时任务已创建，每1分钟执行一次！"
            systemctl enable --now ddns.service >/dev/null 2>&1
            systemctl enable --now ddns.timer >/dev/null 2>&1
        else
            echo -e "${Tip}服务和定时器单元文件已存在，无需再次创建！"
        fi
    fi
}

# 更改 DDNS 服务的运行时间（单位：分钟）
set_ddns_run_interval() {
    read -rp "请输入新的 DDNS 运行间隔（分钟）： " interval

    # 输入验证
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo -e "${Error}无效输入！请输入一个正整数。"
        return 1
    fi

    if grep -qiE "alpine" /etc/os-release; then
        # 在 Alpine Linux 上更新 cron 任务
        echo -e "${Info}正在更新 DDNS 脚本的 cron 任务... "

        # 计算 cron 表达式
        local cron_time="*/$interval * * * * /bin/bash /etc/DDNS/DDNS >/dev/null 2>&1"

        # 检查 cron 任务是否已存在，防止重复添加
        if crontab -l | grep -q "/etc/DDNS/DDNS"; then
            # 删除旧的 cron 任务
            (crontab -l | grep -v "/etc/DDNS/DDNS") | crontab -
        fi
        # 添加新的 cron 任务
        (crontab -l; echo "$cron_time") | crontab -
        echo -e "${Info}DDNS 脚本已设置为每 ${interval} 分钟运行一次！"
    else
        # 在 Debian/Ubuntu 上更新 systemd 定时器
        echo -e "${Info}正在更新 DDNS 定时器... "

        # 停止并禁用旧的定时器
        systemctl stop ddns.timer
        systemctl disable ddns.timer

        # 修改定时器文件，将单位设置为分钟
        sed -i "s/OnUnitActiveSec=.*s/OnUnitActiveSec=${interval}m/" /etc/systemd/system/ddns.timer

        # 重新加载 systemd 管理器配置
        systemctl daemon-reload

        # 启动并启用新的定时器
        systemctl enable --now ddns.timer
        echo -e "${Info}DDNS 定时器已设置为每 ${interval} 分钟运行一次！"
    fi
}

restart_ddns() {
    if grep -qiE "alpine" /etc/os-release; then
        echo -e "${Info}重新启动 ddns 脚本..."

        # 获取当前的 cron 任务
        current_cron=$(crontab -l | grep "/bin/bash /etc/DDNS/DDNS" || true)

        # 如果当前的 cron 任务存在，则替换
        if [ -n "$current_cron" ]; then
            # 删除旧的 cron 任务
            crontab -l | grep -v "/bin/bash /etc/DDNS/DDNS" | crontab -

            # 添加新的 cron 任务
            new_cron="${current_cron} >/dev/null 2>&1"
            (crontab -l; echo "$new_cron") | crontab -

            echo -e "${Info}DDNS 已重启！"
        else
            echo -e "${Error}未找到现有的 cron 任务，无法重启 DDNS。"
            read -rp "是否要添加一个新的 DDNS 任务（每 2 分钟）？[y/n] " add_cron
            if [[ "$add_cron" == "y" || "$add_cron" == "Y" ]]; then
                # 添加新的 cron 任务
                new_cron="*/2 * * * * /bin/bash /etc/DDNS/DDNS >/dev/null 2>&1"
                (crontab -l; echo "$new_cron") | crontab -
                echo -e "${Info}已添加新的 DDNS 任务，每 2 分钟运行一次！"
            else
                echo -e "${Info}未添加新的 DDNS 任务。"
                return 1  # 返回失败状态
            fi
        fi
    else
        echo -e "${Info}重启 DDNS 服务... "
        systemctl restart ddns.service >/dev/null 2>&1
        systemctl restart ddns.timer >/dev/null 2>&1
        echo -e "${Info}DDNS 已重启！"
    fi
}

# 停止DDNS服务
stop_ddns(){
    if grep -qiE "alpine" /etc/os-release; then
        echo -e "${Info}停止 ddns 脚本..."
        # 从 cron 中移除 ddns 任务
        crontab -l | grep -v "/bin/bash /etc/DDNS/DDNS >/dev/null 2>&1" | crontab -
        echo -e "${Info}DDNS 已停止！"
    else
        echo -e "${Info}停止 DDNS 服务..."
        systemctl stop ddns.service >/dev/null 2>&1
        systemctl stop ddns.timer >/dev/null 2>&1
        echo -e "${Info}DDNS 已停止！"
    fi
}

#查看详细运行状态
show_service_detail() {
    echo -e "${Info}--- 当前配置与状态 ---"
    source /etc/DDNS/.config
    echo -e "IPv4 域名: ${YELLOW}${Domains[*]}${NC}"
    echo -e "IPv6 开启: ${YELLOW}${ipv6_set}${NC}"
    echo -e "最后记录 IP: ${YELLOW}${Old_Public_IPv4:-未记录}${NC}"
    
    if grep -qiE "alpine" /etc/os-release; then
        echo -en "Cron 任务: "
        if crontab -l | grep -q "/etc/DDNS/DDNS"; then
            echo -e "${GREEN}运行中 (Cron)${NC}"
            crontab -l | grep "/etc/DDNS/DDNS"
        else
            echo -e "${RED}未在计划任务中${NC}"
        fi
    else
        echo -en "Systemd 状态: "
        if systemctl is-active --quiet ddns.timer; then
            echo -e "${GREEN}活动中 (Timer)${NC}"
            echo -e "下次运行时间: $(systemctl list-timers | grep ddns.timer | awk '{print $1,$2}')"
        else
            echo -e "${RED}已停止${NC}"
        fi
    fi
    echo
}

#手动测试 TG 通知
test_tg_notification() {
    source /etc/DDNS/.config
    if [[ -z "$Telegram_Bot_Token" || -z "$Telegram_Chat_ID" ]]; then
        echo -e "${Error} 未配置 Telegram Token 或 Chat ID，请先执行选项 6"
        return
    fi
    echo -e "${Info} 正在发送测试消息..."
    test_msg="🔔 DDNS 脚本测试通知\n来自服务器: $(hostname)\n状态: 配置正常"
    
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "text=$test_msg")
    
    if [ "$status_code" -eq 200 ]; then
        echo -e "${GREEN}[成功]${NC} 请检查你的 Telegram 消息！"
    else
        echo -e "${Error} 发送失败，HTTP 状态码: $status_code (请检查 Token 和 Chat ID)"
    fi
}

# 检查是否安装DDNS
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
        echo -e "${Info}执行 ${GREEN}ddns${NC} 可呼出菜单！"
    else
        cop_info
        check_ddns_status
        if [[ "$ddns_status" == "running" ]]; then
            echo -e "${Info}DDNS：${GREEN}已安装${NC} 并 ${GREEN}已启动${NC}"
        else
            echo -e "${Tip}DDNS：${GREEN}已安装${NC} 但 ${RED}未启动${NC}"
            echo -e "${Tip}请选择 ${GREEN}4${NC} 重新配置 Cloudflare Api 或 ${GREEN}5${NC} 配置 Telegram 通知"
        fi
        echo
        go_ahead
    fi
}

check_curl
check_ddns_install
