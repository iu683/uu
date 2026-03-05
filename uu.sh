#!/bin/bash
# ==================================================
# VPS Geo Firewall (Stable + Port Control)
# Debian / Ubuntu
# 支持每日自动更新 IP 库
# ==================================================

CONF="/opt/geoip/geo.conf"
BASE_DIR="/opt/geoip"
CHAIN="GEO_CHAIN"
UPDATE_SCRIPT="$BASE_DIR/update_geo.sh"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# ================= 初始化目录 =================
init_env(){
    mkdir -p $BASE_DIR
    touch $CONF
}

# ================= 原子更新 ipset =================
update_ipset(){
    local NAME=$1
    local FILE=$2
    local FAMILY=$3

    [[ ! -s "$FILE" ]] && return

    ipset create $NAME hash:net family $FAMILY -exist
    ipset create ${NAME}_tmp hash:net family $FAMILY -exist
    ipset flush ${NAME}_tmp

    while read -r ip; do
        [[ -n "$ip" ]] && ipset add ${NAME}_tmp "$ip" 2>/dev/null
    done < "$FILE"

    ipset swap ${NAME}_tmp $NAME
    ipset destroy ${NAME}_tmp
}

# ================= 应用规则 =================
apply_rules(){
    source $CONF 2>/dev/null
    [[ -z "$COUNTRY" || -z "$MODE" || -z "$PORTS" ]] && red "未配置规则" && return

    SSH_PORT=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22

    CC=$(echo $COUNTRY | tr A-Z a-z)
    V4FILE="$BASE_DIR/${CC}.zone"
    V6FILE="$BASE_DIR/${CC}.ipv6.zone"

    # 下载 IP 库
    curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/${CC}.zone
    curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${CC}-aggregated.zone

    update_ipset "geo_v4" "$V4FILE" inet
    update_ipset "geo_v6" "$V6FILE" inet6

    # 创建链
    iptables -N $CHAIN 2>/dev/null
    ip6tables -N $CHAIN 2>/dev/null
    iptables -C INPUT -j $CHAIN 2>/dev/null || iptables -I INPUT -j $CHAIN
    ip6tables -C INPUT -j $CHAIN 2>/dev/null || ip6tables -I INPUT -j $CHAIN

    iptables -F $CHAIN
    ip6tables -F $CHAIN

    # 放行已建立连接
    iptables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # SSH 永远允许
    iptables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    ip6tables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 白名单
    for ip in $WHITELIST; do
        iptables -A $CHAIN -s $ip -j ACCEPT
        ip6tables -A $CHAIN -s $ip -j ACCEPT
    done

    # 应用端口规则
    if [[ "$PORTS" == "all" ]]; then
        for proto in tcp udp; do
            if [[ "$MODE" == "block" ]]; then
                iptables -A $CHAIN -p $proto -m set --match-set geo_v4 src -j DROP
                ip6tables -A $CHAIN -p $proto -m set --match-set geo_v6 src -j DROP
            else
                iptables -A $CHAIN -p $proto -m set ! --match-set geo_v4 src -j DROP
                ip6tables -A $CHAIN -p $proto -m set ! --match-set geo_v6 src -j DROP
            fi
        done
    else
        for p in $PORTS; do
            for proto in tcp udp; do
                if [[ "$MODE" == "block" ]]; then
                    iptables -A $CHAIN -p $proto --dport $p -m set --match-set geo_v4 src -j DROP
                    ip6tables -A $CHAIN -p $proto --dport $p -m set --match-set geo_v6 src -j DROP
                else
                    iptables -A $CHAIN -p $proto --dport $p -m set ! --match-set geo_v4 src -j DROP
                    ip6tables -A $CHAIN -p $proto --dport $p -m set ! --match-set geo_v6 src -j DROP
                fi
            done
        done
    fi

    netfilter-persistent save >/dev/null 2>&1
    green "规则已应用"
}

# ================= 自动更新 IP =================
install_auto_update(){
cat > $UPDATE_SCRIPT <<EOF
#!/bin/bash
source $CONF 2>/dev/null
[[ -z "\$COUNTRY" ]] && exit 0

CC=\$(echo \$COUNTRY | tr A-Z a-z)
BASE="$BASE_DIR"
V4FILE="\$BASE/\${CC}.zone"
V6FILE="\$BASE/\${CC}.ipv6.zone"

curl -s -o \$V4FILE https://www.ipdeny.com/ipblocks/data/countries/\${CC}.zone
curl -s -o \$V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/\${CC}-aggregated.zone
EOF

chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * $UPDATE_SCRIPT") | crontab -
green "已设置每日 03:00 自动更新 IP 库"
}

# ================= 添加规则 =================
add_rule(){
    echo -e "${GREEN}选择模式:${RESET}"
    echo -e "${GREEN}1 封锁某国某端口${RESET}"
    echo -e "${GREEN}2 封锁某国所有端口${RESET}"
    echo -e "${GREEN}3 只允许某国某端口${RESET}"
    echo -e "${GREEN}4 只允许某国访问整个服务器${RESET}"
    read -p $'\033[32m选择模式(1-4): \033[0m' choice

    case $choice in
        1) MODE="block" ;;
        2) MODE="block" ;;
        3) MODE="allow" ;;
        4) MODE="allow" ;;
        *) red "无效选择" ; return ;;
    esac

    read -p $'\033[32m国家代码 (如 cn jp us): \033[0m' COUNTRY

    if [[ $choice == 1 || $choice == 3 ]]; then
        read -p $'\033[32m端口 (空格分隔): \033[0m' PORTS
    else
        PORTS="all"
    fi

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    install_auto_update
    apply_rules
}

# ================= 删除指定端口规则 =================
delete_rule(){
    source $CONF 2>/dev/null
    [[ -z "$PORTS" ]] && red "未检测到配置" && return

    read -p $'\033[32m输入要删除端口 (空格分隔): \033[0m' DEL_PORTS
    [[ -z "$DEL_PORTS" ]] && red "未输入端口" && return

    for p in $DEL_PORTS; do
        for proto in tcp udp; do
            iptables -L $CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do
                iptables -D $CHAIN $num
            done
            ip6tables -L $CHAIN --line-numbers -n | grep "$proto" | grep "dpt:$p" | awk '{print $1}' | sort -rn | while read num; do
                ip6tables -D $CHAIN $num
            done
        done
        green "端口 $p 规则已删除"
    done

    netfilter-persistent save >/dev/null 2>&1
}

# ================= 白名单 =================
add_whitelist(){
    read -p $'\033[32m输入白名单 IP (多个空格): \033[0m' ips
    source $CONF 2>/dev/null
    WHITELIST="$WHITELIST $ips"

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    # 应用规则
    iptables -N $CHAIN 2>/dev/null
    ip6tables -N $CHAIN 2>/dev/null
    iptables -C INPUT -j $CHAIN 2>/dev/null || iptables -I INPUT -j $CHAIN
    ip6tables -C INPUT -j $CHAIN 2>/dev/null || ip6tables -I INPUT -j $CHAIN

    # 放行已建立连接
    iptables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # SSH 永远允许
    SSH_PORT=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    iptables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    ip6tables -A $CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 白名单按类型加入
    for ip in $WHITELIST; do
        if [[ $ip == *:* ]]; then
            # IPv6
            ip6tables -A $CHAIN -s $ip -j ACCEPT
        else
            # IPv4
            iptables -A $CHAIN -s $ip -j ACCEPT
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
    green "白名单已更新"
}

# ================= 查看 =================
view_rules(){
    clear
    green "========= 当前配置 ========="
    cat $CONF 2>/dev/null
    echo
    iptables -L $CHAIN -n --line-numbers 2>/dev/null
    echo
    ipset list | grep "^Name:"
}

# ================= 卸载 =================
uninstall_all(){
    iptables -D INPUT -j $CHAIN 2>/dev/null
    ip6tables -D INPUT -j $CHAIN 2>/dev/null
    iptables -F $CHAIN 2>/dev/null
    ip6tables -F $CHAIN 2>/dev/null
    iptables -X $CHAIN 2>/dev/null
    ip6tables -X $CHAIN 2>/dev/null

    ipset destroy geo_v4 2>/dev/null
    ipset destroy geo_v6 2>/dev/null

    rm -rf $BASE_DIR

    netfilter-persistent save >/dev/null 2>&1
    green "已卸载完成"
    exit 0
}

# ================= 菜单 =================
menu(){
clear
echo -e "${GREEN}===== Geo Firewall =====${RESET}"
echo -e "${GREEN}1 添加规则${RESET}"
echo -e "${GREEN}2 删除端口规则${RESET}"
echo -e "${GREEN}3 添加白名单${RESET}"
echo -e "${GREEN}4 查看规则${RESET}"
echo -e "${GREEN}5 卸载${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -p $'\033[32m请选择: \033[0m' num

case $num in
1) add_rule ;;
2) delete_rule ;;
3) add_whitelist ;;
4) view_rules ;;
5) uninstall_all ;;
0) exit ;;
esac
}

# ================= 主循环 =================
init_env
while true; do
    menu
    read -p $'\033[32m按回车继续...\033[0m'
done