#!/bin/bash
# ==================================================
# VPS 国家 IP 防火墙 Pro v3
# 支持 Debian / Ubuntu
# 独立 GEO_CHAIN / IPv4+IPv6 / nft兼容 / Docker安全
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }
yellow(){ echo -e "${YELLOW}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# ================= 初始化环境 =================
init_env(){
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1
        apt install -y ipset iptables curl iptables-persistent >/dev/null 2>&1
    else
        red "仅支持 Debian / Ubuntu"
        exit 1
    fi

    mkdir -p /opt/geoip
    touch $CONF
}

# ================= 获取公网IP =================
get_my_ip(){
    $(hostname -I | awk '{print $1}')
}

# ================= 应用规则 =================
apply_rules(){

    source $CONF 2>/dev/null

    if [[ -z "$COUNTRIES" ]]; then
        red "未配置国家规则"
        return
    fi

    if iptables -V | grep -q nf_tables; then
        BACKEND="nft"
    else
        BACKEND="legacy"
    fi
    green "iptables 后端: $BACKEND"

    # 创建独立链
    iptables -N GEO_CHAIN 2>/dev/null
    ip6tables -N GEO_CHAIN 2>/dev/null

    # 挂载一次
    iptables -C INPUT -j GEO_CHAIN 2>/dev/null || iptables -I INPUT -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT -j GEO_CHAIN

    # 清空链
    iptables -F GEO_CHAIN
    ip6tables -F GEO_CHAIN

    # 允许已建立连接
    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 白名单
    for ip in $WHITELIST; do
        iptables -A GEO_CHAIN -s $ip -j ACCEPT
        ip6tables -A GEO_CHAIN -s $ip -j ACCEPT 2>/dev/null
    done

    # 当前IP保护
    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && iptables -A GEO_CHAIN -s $MYIP -j ACCEPT

    for CC in $COUNTRIES; do
        CC_L=$(echo $CC | tr A-Z a-z)

        V4SET="geo_${CC_L}_v4"
        V6SET="geo_${CC_L}_v6"

        V4FILE="/opt/geoip/${CC_L}.zone"
        V6FILE="/opt/geoip/${CC_L}.ipv6.zone"

        curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
        curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone

        ipset create $V4SET hash:net family inet -exist
        ipset create $V6SET hash:net family inet6 -exist

        ipset flush $V4SET
        ipset flush $V6SET

        while read ip; do ipset add $V4SET $ip; done < $V4FILE
        while read ip; do ipset add $V6SET $ip; done < $V6FILE 2>/dev/null

        if [[ "$MODE" == "block" ]]; then
            iptables -A GEO_CHAIN -m set --match-set $V4SET src -j DROP
            ip6tables -A GEO_CHAIN -m set --match-set $V6SET src -j DROP
        else
            iptables -A GEO_CHAIN -m set ! --match-set $V4SET src -j DROP
            ip6tables -A GEO_CHAIN -m set ! --match-set $V6SET src -j DROP
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
    green "规则已成功应用（Docker安全模式）"
}

# ================= 创建更新任务 =================
create_update(){
cat > $UPDATE_SCRIPT <<EOF
#!/bin/bash
source $CONF
for CC in \$COUNTRIES; do
    CC_L=\$(echo \$CC | tr A-Z a-z)
    V4SET="geo_\${CC_L}_v4"
    V6SET="geo_\${CC_L}_v6"
    V4FILE="/opt/geoip/\${CC_L}.zone"
    V6FILE="/opt/geoip/\${CC_L}.ipv6.zone"

    curl -s -o \$V4FILE https://www.ipdeny.com/ipblocks/data/countries/\$CC_L.zone
    curl -s -o \$V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/\$CC_L-aggregated.zone

    ipset flush \$V4SET
    ipset flush \$V6SET

    while read ip; do ipset add \$V4SET \$ip; done < \$V4FILE
    while read ip; do ipset add \$V6SET \$ip; done < \$V6FILE 2>/dev/null
done
EOF

chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 4 * * * $UPDATE_SCRIPT") | crontab -
}

# ================= 添加规则 =================
add_rule(){
    read -p "模式 (1=封锁 2=只允许): " m
    [[ $m == 1 ]] && MODE="block" || MODE="allow"

    read -p "国家代码 (如 cn jp us): " COUNTRIES
    read -p "端口控制 (当前版本全端口控制): " tmp

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    apply_rules
    create_update
}

# ================= 白名单 =================
add_whitelist(){
    read -p "输入白名单IP (多个空格): " ips
    source $CONF 2>/dev/null
    WHITELIST="$WHITELIST $ips"
    echo "WHITELIST=\"$WHITELIST\"" > $CONF
    echo "MODE=\"$MODE\"" >> $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    apply_rules
}

# ================= 删除规则 =================
delete_rules(){
    iptables -D INPUT -j GEO_CHAIN 2>/dev/null
    ip6tables -D INPUT -j GEO_CHAIN 2>/dev/null

    iptables -F GEO_CHAIN 2>/dev/null
    ip6tables -F GEO_CHAIN 2>/dev/null

    iptables -X GEO_CHAIN 2>/dev/null
    ip6tables -X GEO_CHAIN 2>/dev/null

    ipset list | grep "^Name: geo_" | awk '{print $2}' | xargs -r -I {} ipset destroy {}

    > $CONF
    green "国家规则已删除"
}

# ================= 卸载 =================
uninstall(){
    delete_rules
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    green "已完全卸载"
}

# ================= 菜单 =================
menu(){
clear
echo -e "${GREEN}====== VPS国家防火墙 ======${RESET}"
echo -e "${GREEN}1 添加/修改规则${RESET}"
echo -e "${GREEN}2 添加白名单${RESET}"
echo -e "${GREEN}3 删除规则${RESET}"
echo -e "${GREEN}4 卸载程序${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -r -p $'\033[32m请选择: \033[0m' num

case $num in
1) add_rule ;;
2) add_whitelist ;;
3) delete_rules ;;
4) uninstall ;;
0) exit ;;
esac
}

# ================= 主程序 =================
init_env
while true; do
    menu
    read -p "按回车继续..."
done
