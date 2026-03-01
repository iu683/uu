#!/bin/bash
# ==================================================
# VPS Geo Firewall Pro v3.2 Enterprise
# Debian / Ubuntu
# 独立链 / IPv4+IPv6 / 端口控制 / 自动更新 / 卸载
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"

SCRIPT_PATH="/usr/local/bin/geofirewall"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/mm.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1



# ================== 检测并切换 iptables 模式 ==================
check_iptables_mode(){

    IPT_MODE=$(iptables -V 2>/dev/null)

    if echo "$IPT_MODE" | grep -q "nf_tables"; then
        echo -e "${YELLOW}检测到 nft 模式，正在切换到 legacy...${RESET}"

        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null

        echo -e "${GREEN}已切换到 iptables-legacy${RESET}"
    else
        echo -e "${GREEN}当前为 legacy 模式，无需切换${RESET}"
    fi
}

# ================== 检测并关闭 UFW ==================
check_ufw(){

    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -n1)

        if echo "$UFW_STATUS" | grep -qi "active"; then
            echo -e "${YELLOW}检测到 UFW 已启用，正在关闭...${RESET}"
            ufw disable >/dev/null 2>&1
            echo -e "${GREEN}UFW 已关闭${RESET}"
        else
            echo -e "${GREEN}UFW 未启用${RESET}"
        fi
    fi
}

# ================== 初始化环境 ==================
init_env(){

    echo "正在检测依赖..."

    for pkg in ipset iptables curl iptables-persistent; do
        if ! command -v $pkg >/dev/null 2>&1; then
            echo "安装 $pkg ..."
            apt install -y $pkg
        fi
    done

    check_iptables_mode
    check_ufw

    mkdir -p /opt/geoip
    touch $CONF
}
# ================== 下载或更新脚本 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    green "已更新"
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
[[ -z "\$COUNTRIES" ]] && exit 0

for CC in \$COUNTRIES; do
    CC_L=\$(echo \$CC | tr A-Z a-z)
    curl -s -o /opt/geoip/\${CC_L}.zone https://www.ipdeny.com/ipblocks/data/countries/\${CC_L}.zone
    curl -s -o /opt/geoip/\${CC_L}.ipv6.zone https://www.ipdeny.com/ipv6/ipaddresses/aggregated/\${CC_L}-aggregated.zone
done
EOF

chmod +x $UPDATE_SCRIPT
(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * $UPDATE_SCRIPT") | crontab -

green "已设置每日 03:00 自动更新IP库"
}

# ================== 应用规则 ==================
apply_rules(){

    source $CONF 2>/dev/null
    [[ -z "$COUNTRIES" ]] && red "未配置规则" && return

    SSH_PORT=$(get_ssh_port)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    green "检测到 SSH 端口: $SSH_PORT"

    # ===== 创建主链（不存在才创建）=====
    iptables  -L GEO_CHAIN >/dev/null 2>&1 || iptables  -N GEO_CHAIN
    ip6tables -L GEO_CHAIN >/dev/null 2>&1 || ip6tables -N GEO_CHAIN

    iptables  -C INPUT -j GEO_CHAIN 2>/dev/null || iptables  -I INPUT -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT -j GEO_CHAIN

    # ===== 基础放行规则（防重复）=====
    iptables -C GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    ip6tables -C GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && \
    iptables -C GEO_CHAIN -s $MYIP -j ACCEPT 2>/dev/null || \
    iptables -A GEO_CHAIN -s $MYIP -j ACCEPT

    iptables -C GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || \
    iptables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    ip6tables -C GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || \
    ip6tables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # ===== 白名单 =====
    for ip in $WHITELIST; do
        iptables  -C GEO_CHAIN -s $ip -j ACCEPT 2>/dev/null || \
        iptables  -A GEO_CHAIN -s $ip -j ACCEPT

        ip6tables -C GEO_CHAIN -s $ip -j ACCEPT 2>/dev/null || \
        ip6tables -A GEO_CHAIN -s $ip -j ACCEPT
    done

    # ===== 国家规则 =====
    for CC in $COUNTRIES; do
        CC_L=$(echo $CC | tr A-Z a-z)

        V4SET="geo_${CC_L}_v4"
        V6SET="geo_${CC_L}_v6"

        V4FILE="/opt/geoip/${CC_L}.zone"
        V6FILE="/opt/geoip/${CC_L}.ipv6.zone"

        # 下载IP库
        curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
        curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone

        # 创建ipset（不删除旧数据）
        ipset create $V4SET hash:net family inet -exist
        ipset create $V6SET hash:net family inet6 -exist

        while read -r ip; do
            [[ -n "$ip" ]] && ipset add $V4SET "$ip" 2>/dev/null
        done < "$V4FILE"

        [[ -f "$V6FILE" ]] && while read -r ip; do
            [[ -n "$ip" ]] && ipset add $V6SET "$ip" 2>/dev/null
        done < "$V6FILE"

        # ===== 应用iptables规则 =====
        if [[ "$PORTS" == "all" ]]; then
            for proto in tcp udp; do
                if [[ "$MODE" == "block" ]]; then

                    iptables  -C GEO_CHAIN -p $proto -m set --match-set $V4SET src -j DROP 2>/dev/null || \
                    iptables  -A GEO_CHAIN -p $proto -m set --match-set $V4SET src -j DROP

                    ip6tables -C GEO_CHAIN -p $proto -m set --match-set $V6SET src -j DROP 2>/dev/null || \
                    ip6tables -A GEO_CHAIN -p $proto -m set --match-set $V6SET src -j DROP

                else

                    iptables  -C GEO_CHAIN -p $proto -m set ! --match-set $V4SET src -j DROP 2>/dev/null || \
                    iptables  -A GEO_CHAIN -p $proto -m set ! --match-set $V4SET src -j DROP

                    ip6tables -C GEO_CHAIN -p $proto -m set ! --match-set $V6SET src -j DROP 2>/dev/null || \
                    ip6tables -A GEO_CHAIN -p $proto -m set ! --match-set $V6SET src -j DROP

                fi
            done
        else
            for p in $PORTS; do
                for proto in tcp udp; do
                    if [[ "$MODE" == "block" ]]; then

                        iptables  -C GEO_CHAIN -p $proto --dport $p -m set --match-set $V4SET src -j DROP 2>/dev/null || \
                        iptables  -A GEO_CHAIN -p $proto --dport $p -m set --match-set $V4SET src -j DROP

                        ip6tables -C GEO_CHAIN -p $proto --dport $p -m set --match-set $V6SET src -j DROP 2>/dev/null || \
                        ip6tables -A GEO_CHAIN -p $proto --dport $p -m set --match-set $V6SET src -j DROP

                    else

                        iptables  -C GEO_CHAIN -p $proto --dport $p -m set ! --match-set $V4SET src -j DROP 2>/dev/null || \
                        iptables  -A GEO_CHAIN -p $proto --dport $p -m set ! --match-set $V4SET src -j DROP

                        ip6tables -C GEO_CHAIN -p $proto --dport $p -m set ! --match-set $V6SET src -j DROP 2>/dev/null || \
                        ip6tables -A GEO_CHAIN -p $proto --dport $p -m set ! --match-set $V6SET src -j DROP

                    fi
                done
            done
        fi
    done

    netfilter-persistent save >/dev/null 2>&1
    green "Geo v4/v6 防火墙规则已成功应用"
}

# ================== 添加规则 ==================
add_rule(){
    read -p "模式 (1=封锁 2=只允许): " m
    [[ $m == 1 ]] && MODE="block" || MODE="allow"
    read -p "国家代码 (如 cn jp us): " COUNTRIES
    read -p "端口 (all 或 22 80 多个空格分隔): " PORTS

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    install_auto_update
    apply_rules
}

# ================== 白名单 ==================
add_whitelist(){
    read -p "输入要加入白名单IP (多个空格分隔): " ips
    source $CONF 2>/dev/null
    WHITELIST="$WHITELIST $ips"

    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRIES=\"$COUNTRIES\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF

    green "白名单已更新"
    apply_rules
}

# ================== 查看规则 ==================
view_rules(){
    clear
    green "========= 当前配置 ========="
    cat $CONF 2>/dev/null
    echo
    iptables -L GEO_CHAIN -n --line-numbers 2>/dev/null
    echo
    ipset list | grep "^Name:"
}


# ================== 删除指定端口规则 ==================
delete_rules(){

    source $CONF 2>/dev/null
    [[ -z "$PORTS" ]] && red "未检测到配置" && return

    read -p "输入要删除的端口 (如 80 多个空格): " DEL_PORTS
    [[ -z "$DEL_PORTS" ]] && red "未输入端口" && return

    for p in $DEL_PORTS; do
        for proto in tcp udp; do

            # 删除 IPv4 规则
            iptables -L GEO_CHAIN --line-numbers -n | \
            grep "$proto" | grep "dpt:$p" | \
            awk '{print $1}' | sort -rn | \
            while read num; do
                iptables -D GEO_CHAIN $num
            done

            # 删除 IPv6 规则
            ip6tables -L GEO_CHAIN --line-numbers -n | \
            grep "$proto" | grep "dpt:$p" | \
            awk '{print $1}' | sort -rn | \
            while read num; do
                ip6tables -D GEO_CHAIN $num
            done

        done
        green "端口 $p 规则已删除"
    done

    netfilter-persistent save >/dev/null 2>&1
}

# ================== 卸载 ==================
uninstall_all(){

    green "正在卸载"

    # 删除规则
    iptables -D INPUT -j GEO_CHAIN 2>/dev/null
    ip6tables -D INPUT -j GEO_CHAIN 2>/dev/null
    iptables -F GEO_CHAIN 2>/dev/null
    ip6tables -F GEO_CHAIN 2>/dev/null
    iptables -X GEO_CHAIN 2>/dev/null
    ip6tables -X GEO_CHAIN 2>/dev/null

    # 删除 ipset
    ipset list | grep "^Name: geo_" | awk '{print $2}' | xargs -r -I {} ipset destroy {}

    # 删除配置和更新脚本
    rm -rf /opt/geoip

    # 删除定时任务
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -

    # 删除主程序
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
echo -e "${GREEN}2 删除规则${RESET}"
echo -e "${GREEN}3 查看规则${RESET}"
echo -e "${GREEN}4 添加白名单${RESET}"
echo -e "${GREEN}5 更新${RESET}"
echo -e "${GREEN}6 卸载${RESET}"
echo -e "${GREEN}0 退出${RESET}"
read -r -p $'\033[32m请选择: \033[0m' num
case $num in
1) add_rule ;;
2) delete_rules ;;
3) view_rules ;;
4) add_whitelist ;;
5) download_script ;;
6) uninstall_all ;;
0) exit ;;
esac
}

# ================== 主循环 ==================
init_env
while true; do
    menu
    read -p "按回车继续..."
done
