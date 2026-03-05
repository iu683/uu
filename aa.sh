#!/bin/bash
# ==================================================
# VPS Geo Firewall (IPv4+IPv6)
# Debian / Ubuntu
# 独立链 / 端口控制 / 自动更新 / 白名单 / 卸载
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"
SCRIPT_PATH="/usr/local/bin/geofirewall"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# ================== 初始化环境 ==================
init_env(){
    mkdir -p /opt/geoip
    touch $CONF

    # 仅第一次安装依赖
    if [[ ! -f /opt/geoip/.deps_installed ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ipset iptables curl iptables-persistent netfilter-persistent
        touch /opt/geoip/.deps_installed
        green "依赖安装完成"
    fi
}

# ================== 下载或更新脚本 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    green "脚本已更新"
}

# ================== 获取信息 ==================
get_my_ip(){ hostname -I | awk '{print $1}'; }
get_ssh_port(){
    grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1
}

# ================== 自动更新IP库 ==================
install_auto_update(){
cat > $UPDATE_SCRIPT <<EOF
#!/bin/bash
CONF="/opt/geoip/geo.conf"
source \$CONF 2>/dev/null
[[ -z "\$COUNTRY" ]] && exit 0
CC_L=\$(echo \$COUNTRY | tr A-Z a-z)
curl -s -o /opt/geoip/\${CC_L}.zone https://www.ipdeny.com/ipblocks/data/countries/\${CC_L}.zone
curl -s -o /opt/geoip/\${CC_L}.ipv6.zone https://www.ipdeny.com/ipv6/ipaddresses/aggregated/\${CC_L}-aggregated.zone
EOF

chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * $UPDATE_SCRIPT") | crontab -
green "每日 03:00 自动更新IP库"
}

# ================== 原子更新 ipset ==================
update_ipset(){
    local SET_NAME=$1
    local FILE=$2
    local FAMILY=$3

    [[ ! -s "$FILE" ]] && { red "IP库文件为空 $SET_NAME"; return 1; }

    ipset create $SET_NAME hash:net family $FAMILY -exist
    ipset create ${SET_NAME}_tmp hash:net family $FAMILY -exist
    ipset flush ${SET_NAME}_tmp

    while read -r ip; do
        [[ -n "$ip" ]] && ipset add ${SET_NAME}_tmp "$ip" 2>/dev/null
    done < "$FILE"

    ipset swap ${SET_NAME}_tmp $SET_NAME
    ipset destroy ${SET_NAME}_tmp
    return 0
}

# ================== 应用规则 ==================
apply_rules(){
    source $CONF 2>/dev/null
    [[ -z "$COUNTRY" ]] && { red "未配置规则"; return; }

    SSH_PORT=$(get_ssh_port)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    green "默认放行SSH端口: $SSH_PORT"

    # 创建 GEO_CHAIN 链
    iptables -N GEO_CHAIN 2>/dev/null
    ip6tables -N GEO_CHAIN 2>/dev/null
    iptables -F GEO_CHAIN
    ip6tables -F GEO_CHAIN

    # INPUT 链跳转
    iptables -C INPUT -j GEO_CHAIN 2>/dev/null || iptables -I INPUT -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT -j GEO_CHAIN

    # 基础规则
    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && iptables -A GEO_CHAIN -s $MYIP -j ACCEPT

    iptables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    ip6tables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 白名单
    for ip in $WHITELIST; do
        [[ -n "$ip" ]] && {
            iptables -I GEO_CHAIN 2 -s $ip -j ACCEPT
            ip6tables -I GEO_CHAIN 2 -s $ip -j ACCEPT
        }
    done

    CC_L=$(echo $COUNTRY | tr A-Z a-z)
    V4FILE="/opt/geoip/${CC_L}.zone"
    V6FILE="/opt/geoip/${CC_L}.ipv6.zone"

    curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
    curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone

    update_ipset geo_v4 $V4FILE inet
    update_ipset geo_v6 $V6FILE inet6

    # 封锁/允许规则
    for proto in tcp udp; do
        if [[ "$MODE" == "block" ]]; then
            if [[ "$PORTS" == "all" ]]; then
                iptables -A GEO_CHAIN -p $proto -m set --match-set geo_v4 src -j DROP
                ip6tables -A GEO_CHAIN -p $proto -m set --match-set geo_v6 src -j DROP
            else
                for p in $PORTS; do
                    iptables -A GEO_CHAIN -p $proto --dport $p -m set --match-set geo_v4 src -j DROP
                    ip6tables -A GEO_CHAIN -p $proto --dport $p -m set --match-set geo_v6 src -j DROP
                done
            fi
        else
            if [[ "$PORTS" == "all" ]]; then
                iptables -A GEO_CHAIN -p $proto -m set ! --match-set geo_v4 src -j DROP
                ip6tables -A GEO_CHAIN -p $proto -m set ! --match-set geo_v6 src -j DROP
            else
                for p in $PORTS; do
                    iptables -A GEO_CHAIN -p $proto --dport $p -m set ! --match-set geo_v4 src -j DROP
                    ip6tables -A GEO_CHAIN -p $proto --dport $p -m set ! --match-set geo_v6 src -j DROP
                done
            fi
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
    green "规则已成功应用"
}

# ================== 添加规则 ==================
add_rule(){
    echo -e "${GREEN}选择模式:${RESET}"
    echo -e "${GREEN}1 封锁某国某端口${RESET}"
    echo -e "${GREEN}2 封锁某国所有端口${RESET}"
    echo -e "${GREEN}3 只允许某国某端口${RESET}"
    echo -e "${GREEN}4 只允许某国访问整个服务器${RESET}"
    read -p $'\033[32m选择模式(1-4): \033[0m' choice

    case "$choice" in
        1)
            MODE="block"
            read -p $'\033[32m国家代码: \033[0m' COUNTRY
            read -p $'\033[32m端口 (多个空格): \033[0m' PORTS
            ;;
        2)
            MODE="block"
            read -p $'\033[32m国家代码(例如 cn us jp): \033[0m' COUNTRY
            PORTS="all"
            ;;
        3)
            MODE="allow"
            read -p $'\033[32m国家代码(例如 cn us jp): \033[0m' COUNTRY
            read -p $'\033[32m端口(例如 443 80 多个空格): \033[0m' PORTS
            ;;
        4)
            MODE="allow"
            read -p $'\033[32m国家代码(例如 cn us jp): \033[0m' COUNTRY
            PORTS="all"
            ;;
        *)
            red "无效选择"
            return
            ;;
    esac

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    install_auto_update
    apply_rules
}

# ================== 白名单 ==================
add_whitelist(){
    read -p $'\033[32m输入白名单 IP (多个空格): \033[0m' ips
    source $CONF 2>/dev/null
    WHITELIST="$WHITELIST $ips"
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
    apply_rules
}

delete_whitelist(){
    read -p $'\033[32m输入要删除的白名单 IP (多个空格): \033[0m' ips
    source $CONF 2>/dev/null
    for ip in $ips; do
        WHITELIST=$(echo $WHITELIST | sed -E "s/\b$ip\b//g")
    done
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
    apply_rules
}

# ================== 删除端口规则 ==================
delete_rules(){
    source $CONF 2>/dev/null
    [[ -z "$PORTS" ]] && { red "未检测到配置"; return; }
    read -p $'\033[32m输入要删除的端口 (多个空格): \033[0m' DEL_PORTS
    [[ -z "$DEL_PORTS" ]] && { red "未输入端口"; return; }
    for p in $DEL_PORTS; do
        for proto in tcp udp; do
            iptables -L GEO_CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do
                iptables -D GEO_CHAIN $num
            done
            ip6tables -L GEO_CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do
                ip6tables -D GEO_CHAIN $num
            done
        done
        green "端口 $p 规则已删除"
    done
    netfilter-persistent save >/dev/null 2>&1
}

# ================== 查看规则 ==================
view_rules(){
    clear
    green "========= 当前配置 ========="
    cat $CONF 2>/dev/null
    echo
    iptables -L GEO_CHAIN -n --line-numbers 2>/dev/null
    echo
    ip6tables -L GEO_CHAIN -n --line-numbers 2>/dev/null
    echo
    ipset list | grep "^Name:"
}

# ================== 卸载 ==================
uninstall_all(){
    green "正在卸载"
    iptables -D INPUT -j GEO_CHAIN 2>/dev/null
    ip6tables -D INPUT -j GEO_CHAIN 2>/dev/null
    iptables -F GEO_CHAIN 2>/dev/null
    ip6tables -F GEO_CHAIN 2>/dev/null
    iptables -X GEO_CHAIN 2>/dev/null
    ip6tables -X GEO_CHAIN 2>/dev/null
    ipset list | grep "^Name: geo_" | awk '{print $2}' | xargs -r -I {} ipset destroy {}
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    rm -f $SCRIPT_PATH
    netfilter-persistent save >/dev/null 2>&1
    green "已彻底卸载完成"
    exit 0
}

# ================== 菜单 ==================
menu(){
    clear
    echo -e "${GREEN}===== VPS国家防火墙 =====${RESET}"
    echo -e "${GREEN}1 添加规则${RESET}"
    echo -e "${GREEN}2 删除端口规则${RESET}"
    echo -e "${GREEN}3 查看规则${RESET}"
    echo -e "${GREEN}4 添加白名单${RESET}"
    echo -e "${GREEN}5 删除白名单${RESET}"
    echo -e "${GREEN}6 更新脚本${RESET}"
    echo -e "${GREEN}7 卸载${RESET}"
    echo -e "${GREEN}0 退出${RESET}"
    read -r -p $'\033[32m请选择: \033[0m' num
    case $num in
        1) add_rule ;;
        2) delete_rules ;;
        3) view_rules ;;
        4) add_whitelist ;;
        5) delete_whitelist ;;
        6) download_script ;;
        7) uninstall_all ;;
        0) exit ;;
    esac
}

# ================== 主循环 ==================
init_env
while true; do
    menu
    read -r -p $'\033[32m按回车继续...\033[0m'
done