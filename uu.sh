#!/bin/bash
# ==================================================
# VPS Geo Firewall Pro v3.2 Enterprise
# Debian / Ubuntu
# 独立链 / IPv4+IPv6 / 端口控制 / Docker安全
# 白名单 / 删除规则 / 卸载程序
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# ================= 初始化 =================
init_env(){
    apt update -y >/dev/null 2>&1
    apt install -y ipset iptables curl iptables-persistent >/dev/null 2>&1
    mkdir -p /opt/geoip
    touch $CONF
}

# ================= 工具函数 =================
get_my_ip(){
    curl -s ifconfig.me
}

get_ssh_port(){
    grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1
}

load_conf(){
    source $CONF 2>/dev/null
}

save_conf(){
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
}

# ================= 应用规则 =================
apply_rules(){

    load_conf
    [[ -z "$COUNTRIES" ]] && red "未配置国家规则" && return

    SSH_PORT=$(get_ssh_port)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22

    iptables -N GEO_CHAIN 2>/dev/null
    ip6tables -N GEO_CHAIN 2>/dev/null

    iptables -C INPUT -j GEO_CHAIN 2>/dev/null || iptables -I INPUT -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT -j GEO_CHAIN

    iptables -F GEO_CHAIN
    ip6tables -F GEO_CHAIN

    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 当前IP保护
    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && iptables -A GEO_CHAIN -s $MYIP -j ACCEPT

    # SSH保护
    iptables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 白名单
    for ip in $WHITELIST; do
        iptables -A GEO_CHAIN -s $ip -j ACCEPT
        ip6tables -A GEO_CHAIN -s $ip -j ACCEPT 2>/dev/null
    done

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

        while read -r ip; do
            [[ -n "$ip" ]] && ipset add $V4SET "$ip" 2>/dev/null
        done < "$V4FILE"

        if [[ -f "$V6FILE" ]]; then
            while read -r ip; do
                [[ -n "$ip" ]] && ipset add $V6SET "$ip" 2>/dev/null
            done < "$V6FILE"
        fi

        if [[ "$PORTS" == "all" ]]; then
            if [[ "$MODE" == "block" ]]; then
                iptables -A GEO_CHAIN -m set --match-set $V4SET src -j DROP
                ip6tables -A GEO_CHAIN -m set --match-set $V6SET src -j DROP
            else
                iptables -A GEO_CHAIN -m set ! --match-set $V4SET src -j DROP
                ip6tables -A GEO_CHAIN -m set ! --match-set $V6SET src -j DROP
            fi
        else
            for p in $PORTS; do
                if [[ "$MODE" == "block" ]]; then
                    iptables -A GEO_CHAIN -p tcp --dport $p -m set --match-set $V4SET src -j DROP
                    iptables -A GEO_CHAIN -p udp --dport $p -m set --match-set $V4SET src -j DROP
                else
                    iptables -A GEO_CHAIN -p tcp --dport $p -m set ! --match-set $V4SET src -j DROP
                    iptables -A GEO_CHAIN -p udp --dport $p -m set ! --match-set $V4SET src -j DROP
                fi
            done
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
    green "规则已应用"
}

# ================= 添加规则 =================
add_rule(){
    read -p "模式 (1=封锁 2=只允许): " m
    [[ $m == 1 ]] && MODE="block" || MODE="allow"
    read -p "国家代码 (如 cn jp us): " COUNTRIES
    read -p "端口 (all 或 22 80 443 55283): " PORTS
    load_conf
    save_conf
    apply_rules
}

# ================= 添加白名单 =================
add_whitelist(){
    load_conf
    read -p "输入白名单IP (支持多个 空格分隔): " ips
    WHITELIST="$WHITELIST $ips"
    save_conf
    apply_rules
    green "白名单已添加"
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

# ================= 卸载程序 =================
uninstall(){
    delete_rules
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    green "程序已完全卸载"
    exit
}

# ================= 菜单 =================
menu(){
clear
echo -e "${GREEN}===== VPS国家防火墙 =====${RESET}"
echo -e "${GREEN}1 添加/修改规则${RESET}"
echo -e "${GREEN}2 添加白名单${RESET}"
echo -e "${GREEN}3 删除规则${RESET}"
echo -e "${GREEN}4 卸载程序${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -p "请选择: " num

case $num in
1) add_rule ;;
2) add_whitelist ;;
3) delete_rules ;;
4) uninstall ;;
0) exit ;;
esac
}

init_env
while true; do
    menu
    read -p "按回车继续..."
done
