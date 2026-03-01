#!/bin/bash
# ==========================================
# VPS 国家IP防火墙 Pro
# 支持菜单管理 / 卸载 / 白名单 / 自动更新
# ==========================================

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

init_env(){
    apt update -y >/dev/null 2>&1
    apt install -y ipset iptables curl iptables-persistent >/dev/null 2>&1
    mkdir -p /opt/geoip
    touch $CONF
}

get_my_ip(){
    curl -s ifconfig.me
}

apply_rules(){
    source $CONF
    iptables -F GEO_RULES 2>/dev/null
    iptables -N GEO_RULES 2>/dev/null

    # 放行白名单
    for ip in $WHITELIST; do
        iptables -I INPUT -s $ip -j ACCEPT
    done

    # 放行当前IP
    MYIP=$(get_my_ip)
    iptables -I INPUT -s $MYIP -j ACCEPT

    for CC in $COUNTRIES; do
        CC_L=$(echo $CC | tr A-Z a-z)
        SET="geo_$CC_L"
        FILE="/opt/geoip/$CC_L.zone"
        curl -s -o $FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
        ipset create $SET hash:net -exist
        ipset flush $SET
        for ip in $(cat $FILE); do
            ipset add $SET $ip
        done

        if [[ "$MODE" == "block" ]]; then
            if [[ "$PORTS" == "all" ]]; then
                iptables -I INPUT -m set --match-set $SET src -j DROP
            else
                for p in $PORTS; do
                    iptables -I INPUT -p tcp --dport $p -m set --match-set $SET src -j DROP
                done
            fi
        else
            if [[ "$PORTS" == "all" ]]; then
                iptables -I INPUT -m set ! --match-set $SET src -j DROP
            else
                for p in $PORTS; do
                    iptables -I INPUT -p tcp --dport $p -m set ! --match-set $SET src -j DROP
                done
            fi
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
}

create_update(){
cat > $UPDATE_SCRIPT <<EOF
#!/bin/bash
source $CONF
for CC in \$COUNTRIES; do
    CC_L=\$(echo \$CC | tr A-Z a-z)
    FILE="/opt/geoip/\$CC_L.zone"
    SET="geo_\$CC_L"
    curl -s -o \$FILE https://www.ipdeny.com/ipblocks/data/countries/\$CC_L.zone
    ipset flush \$SET
    for ip in \$(cat \$FILE); do
        ipset add \$SET \$ip
    done
done
EOF
chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 4 * * * $UPDATE_SCRIPT") | crontab -
}

add_rule(){
    read -p "模式 (1=封锁 2=只允许): " m
    [[ $m == 1 ]] && MODE="block" || MODE="allow"
    read -p "国家代码 (如 cn jp us 多个空格分隔): " COUNTRIES
    read -p "端口 (all 或 22 80 443): " PORTS
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
    apply_rules
    create_update
    green "规则已应用"
}

add_whitelist(){
    read -p "输入白名单IP (多个空格): " ips
    WHITELIST="$WHITELIST $ips"
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
    apply_rules
    green "白名单已添加"
}

view_status(){
    green "==== 当前配置 ===="
    cat $CONF
    echo
    iptables -L -n --line-numbers | grep DROP
}

uninstall(){
    iptables -F
    ipset destroy
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    green "已完全卸载"
}

menu(){
clear
echo -e "${GREEN}====== VPS国家防火墙 ======${RESET}"
echo -e "${GREEN}1 添加/修改规则${RESET}"
echo -e "${GREEN}2 添加白名单${RESET}"
echo -e "${GREEN}3 查看状态${RESET}"
echo -e "${GREEN}4 卸载${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -r -p $'\033[32m请选择: \033[0m' num
case $num in
1) add_rule ;;
2) add_whitelist ;;
3) view_status ;;
4) uninstall ;;
0) exit ;;
esac
}

init_env
while true; do
    menu
    read -p "按回车继续..."
done
