#!/bin/bash
# ==================================================
# VPS Geo Firewall
# Debian / Ubuntu
# 独立链 / IPv4+IPv6 / 端口控制 / 自动更新 / 卸载
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"
SCRIPT_PATH="/usr/local/bin/geofirewall"
SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/GeoFirewall.sh"
CHAIN="GEO_CHAIN"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# ================== 初始化环境 ==================
init_env(){
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ipset iptables curl iptables-persistent netfilter-persistent
    mkdir -p /opt/geoip
    touch $CONF
}

# ================== 自动更新IP库 ==================
install_auto_update(){
cat > $UPDATE_SCRIPT <<EOF
#!/bin/bash
CONF="/opt/geoip/geo.conf"
source \$CONF 2>/dev/null
[[ -z "\$COUNTRY" ]] && exit 0
for CC in \$COUNTRY; do
    CC_L=\$(echo \$CC | tr A-Z a-z)
    curl -s -o /opt/geoip/\${CC_L}.zone https://www.ipdeny.com/ipblocks/data/countries/\${CC_L}.zone
    curl -s -o /opt/geoip/\${CC_L}.ipv6.zone https://www.ipdeny.com/ipv6/ipaddresses/aggregated/\${CC_L}-aggregated.zone
done
EOF

chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * $UPDATE_SCRIPT") | crontab -
green "已设置每日 03:00 自动更新IP库"
}

# ================== 原子更新 ipset ==================
update_ipset(){
    local SET_NAME=$1
    local FILE=$2
    local FAMILY=$3
    [[ ! -s "$FILE" ]] && { red "IP库文件为空，跳过 $SET_NAME"; return 1; }
    ipset create $SET_NAME hash:net family $FAMILY -exist
    ipset create ${SET_NAME}_tmp hash:net family $FAMILY -exist
    ipset flush ${SET_NAME}_tmp
    while read -r ip; do [[ -n "$ip" ]] && ipset add ${SET_NAME}_tmp "$ip" 2>/dev/null; done < "$FILE"
    ipset swap ${SET_NAME}_tmp $SET_NAME
    ipset destroy ${SET_NAME}_tmp
}

# ================== 应用规则 ==================
apply_rules(){
    source $CONF 2>/dev/null
    [[ -z "$COUNTRY" ]] && red "未配置规则" && return

    SSH_PORT=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    green "SSH端口: $SSH_PORT"

    # 创建链
    iptables -N $CHAIN 2>/dev/null
    ip6tables -N $CHAIN 2>/dev/null
    iptables -C INPUT -j $CHAIN 2>/dev/null || iptables -I INPUT -j $CHAIN
    ip6tables -C INPUT -j $CHAIN 2>/dev/null || ip6tables -I INPUT -j $CHAIN

    # 清空链
    iptables -F $CHAIN
    ip6tables -F $CHAIN

    # 放行已建立连接
    iptables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 白名单先放行
    for ip in $WHITELIST; do
        if [[ $ip == *:* ]]; then
            ip6tables -A $CHAIN -s $ip -j ACCEPT
        else
            iptables -A $CHAIN -s $ip -j ACCEPT
        fi
    done

    # SSH 永远允许
    iptables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    ip6tables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 下载国家 IP 库并更新 ipset
    for CC in $COUNTRY; do
        CC_L=$(echo $CC | tr A-Z a-z)
        V4FILE="/opt/geoip/${CC_L}.zone"
        V6FILE="/opt/geoip/${CC_L}.ipv6.zone"
        curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
        curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone
        update_ipset "geo_v4" "$V4FILE" inet
        update_ipset "geo_v6" "$V6FILE" inet6

        for proto in tcp udp; do
            if [[ "$MODE" == "block" ]]; then
                # 封禁端口或全部
                if [[ "$PORTS" == "all" ]]; then
                    iptables -A $CHAIN -p $proto -m set --match-set geo_v4 src -j DROP
                    ip6tables -A $CHAIN -p $proto -m set --match-set geo_v6 src -j DROP
                else
                    for p in $PORTS; do
                        iptables -A $CHAIN -p $proto --dport $p -m set --match-set geo_v4 src -j DROP
                        ip6tables -A $CHAIN -p $proto --dport $p -m set --match-set geo_v6 src -j DROP
                    done
                fi
            else
                # 只允许模式
                if [[ "$PORTS" == "all" ]]; then
                    iptables -A $CHAIN -p $proto -m set ! --match-set geo_v4 src -j DROP
                    ip6tables -A $CHAIN -p $proto -m set ! --match-set geo_v6 src -j DROP
                else
                    for p in $PORTS; do
                        iptables -A $CHAIN -p $proto --dport $p -m set ! --match-set geo_v4 src -j DROP
                        ip6tables -A $CHAIN -p $proto --dport $p -m set ! --match-set geo_v6 src -j DROP
                    done
                fi
            fi
        done
    done

    netfilter-persistent save >/dev/null 2>&1
    green "规则已成功应用"
}

# ================== 添加规则 ==================
add_rule(){
    read -p $'\033[32m模式 (1=封锁 2=只允许): \033[0m' m
    [[ $m == 1 ]] && MODE="block" || MODE="allow"
    read -p $'\033[32m国家代码 (如 cn jp us): \033[0m' COUNTRY
    read -p $'\033[32m端口 (all 或 22 80 多个空格分隔): \033[0m' PORTS

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    install_auto_update
    apply_rules
}

# ================== 添加白名单 ==================
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

# ================== 删除端口规则 ==================
delete_rules(){
    source $CONF 2>/dev/null
    [[ -z "$PORTS" ]] && red "未检测到配置" && return
    read -p $'\033[32m输入要删除的端口 (如 80 多个空格): \033[0m' DEL_PORTS
    [[ -z "$DEL_PORTS" ]] && red "未输入端口" && return
    for p in $DEL_PORTS; do
        for proto in tcp udp; do
            iptables -L $CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do iptables -D $CHAIN $num; done
            ip6tables -L $CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do ip6tables -D $CHAIN $num; done
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
    iptables -L $CHAIN -n --line-numbers 2>/dev/null
    echo
    ipset list | grep "^Name:"
}

# ================== 卸载 ==================
uninstall_all(){
    green "正在卸载"
    iptables -D INPUT -j $CHAIN 2>/dev/null
    ip6tables -D INPUT -j $CHAIN 2>/dev/null
    iptables -F $CHAIN 2>/dev/null
    ip6tables -F $CHAIN 2>/dev/null
    iptables -X $CHAIN 2>/dev/null
    ip6tables -X $CHAIN 2>/dev/null
    ipset list | grep "^Name:" | awk '{print $2}' | xargs -r -I {} ipset destroy {}
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    rm -f $SCRIPT_PATH
    netfilter-persistent save >/dev/null 2>&1
    green "已彻底卸载完成"
    exit 0
}
# ================== 删除白名单 ==================
delete_whitelist(){
    source $CONF 2>/dev/null
    [[ -z "$WHITELIST" ]] && { red "当前白名单为空"; return; }
    echo "当前白名单: $WHITELIST"
    read -p $'\033[32m输入要删除的IP (多个空格分隔): \033[0m' DEL_IPS
    [[ -z "$DEL_IPS" ]] && { red "未输入IP"; return; }

    # 删除指定 IP
    for ip in $DEL_IPS; do
        WHITELIST=$(echo "$WHITELIST" | sed -E "s/(^| )$ip( |$)/ /g")
    done

    # 清理多余空格
    WHITELIST=$(echo "$WHITELIST" | xargs)

    # 写回配置
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    green "已删除指定白名单IP"
    apply_rules
}
# ================== 菜单 ==================
menu(){
clear
echo -e "${GREEN}===== VPS国家防火墙 =====${RESET}"
echo -e "${GREEN}1 添加规则${RESET}"
echo -e "${GREEN}2 删除规则${RESET}"
echo -e "${GREEN}3 查看规则${RESET}"
echo -e "${GREEN}4 添加白名单${RESET}"
echo -e "${GREEN}5 删除白名单${RESET}"
echo -e "${GREEN}6 卸载${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -r -p $'\033[32m请选择: \033[0m' num
case $num in
1) add_rule ;;
2) delete_rules ;;
3) view_rules ;;
4) add_whitelist ;;
5) delete_whitelist ;;
6) uninstall_all ;;
0) exit ;;
esac
}

# ================== 主循环 ==================
init_env
while true; do
    menu
    read -r -p $'\033[32m按回车继续...\033[0m'
done