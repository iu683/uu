#!/bin/bash
# ==================================================
# VPS Geo Firewall (IPv4+IPv6)
# Debian / Ubuntu / Alpine Linux (完美兼容容器与精简环境)
# 独立链 / 端口控制 / 自动更新 / 白名单 / 卸载
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"
SCRIPT_PATH="/usr/local/bin/geofirewall"
SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/GeoFirewall.sh"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

[[ $(id -u) != 0 ]] && red "请使用 root 运行" && exit 1

# 检测系统类型
if [ -f /etc/alpine-release ]; then
    SYS_TYPE="alpine"
else
    SYS_TYPE="debian"
fi

# ================== 初始化环境 ==================
init_env(){
    mkdir -p /opt/geoip
    touch $CONF

    if [[ ! -f /opt/geoip/.deps_installed ]]; then
        if [ "$SYS_TYPE" = "alpine" ]; then
            apk update
            # 无论如何先尝试安装 ipset 和 iptables 相关组件
            apk add ipset iptables ip6tables curl bash ipset-openrc iptables-openrc 2>/dev/null
            rc-update add iptables default 2>/dev/null
            rc-update add ip6tables default 2>/dev/null
            rc-service iptables start 2>/dev/null
            rc-service ip6tables start 2>/dev/null
        else
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y ipset iptables curl iptables-persistent netfilter-persistent
        fi
        touch /opt/geoip/.deps_installed
        green "依赖环境检测完成"
    fi
}

# ================== 下载或更新脚本 ==================
download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    green "已更新"
}

# ================== 获取信息 ==================
get_my_ip(){ 
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n1
}

get_ssh_port(){
    grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1
}

# ================== 规则持久化保存函数 ==================
save_rules(){
    if [ "$SYS_TYPE" = "alpine" ]; then
        /etc/init.d/iptables save >/dev/null 2>&1
        /etc/init.d/ip6tables save >/dev/null 2>&1
    else
        netfilter-persistent save >/dev/null 2>&1
    fi
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
# 重新触发规则应用以更新内存中的IP
/bin/bash $SCRIPT_PATH apply
EOF

    chmod +x $UPDATE_SCRIPT
    (crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * /bin/bash $UPDATE_SCRIPT") | crontab -
    green "每日 03:00 自动更新IP库"
}

# ================== 应用规则 (核心兼容重构) ==================
apply_rules(){
    source $CONF 2>/dev/null
    [[ -z "$COUNTRY" ]] && { red "未配置规则"; return; }

    SSH_PORT=$(get_ssh_port)
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22
    green "默认放行SSH端口: $SSH_PORT"

    CC_L=$(echo $COUNTRY | tr A-Z a-z)
    V4FILE="/opt/geoip/${CC_L}.zone"
    V6FILE="/opt/geoip/${CC_L}.ipv6.zone"

    # 下载最新 IP 库
    curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
    curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone

    # 1. 基础链与跳转初始化
    iptables -N GEO_CHAIN 2>/dev/null
    ip6tables -N GEO_CHAIN 2>/dev/null
    iptables -F GEO_CHAIN
    ip6tables -F GEO_CHAIN

    iptables -C INPUT -j GEO_CHAIN 2>/dev/null || iptables -I INPUT -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT -j GEO_CHAIN

    # Established, Related 放行
    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 放行本地 IP 和 SSH
    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && iptables -A GEO_CHAIN -s $MYIP -j ACCEPT
    iptables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    ip6tables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT

    # 白名单放行
    for ip in $WHITELIST; do
        [[ -n "$ip" ]] && {
            iptables -A GEO_CHAIN -s $ip -j ACCEPT
            ip6tables -A GEO_CHAIN -s $ip -j ACCEPT
        }
    done

    # 2. 判断是否能够运行 ipset
    if [ "$SYS_TYPE" != "alpine" ] && command -v ipset >/dev/null 2>&1; then
        # ------ Debian/Ubuntu 高效 ipset 方案 ------
        ipset create geo_v4 hash:net family inet -exist
        ipset create geo_v4_tmp hash:net family inet -exist
        ipset flush geo_v4_tmp
        while read -r ip; do [[ -n "$ip" ]] && ipset add geo_v4_tmp "$ip" 2>/dev/null; done < "$V4FILE"
        ipset swap geo_v4_tmp geo_v4
        ipset destroy geo_v4_tmp

        ipset create geo_v6 hash:net family inet6 -exist
        ipset create geo_v6_tmp hash:net family inet6 -exist
        ipset flush geo_v6_tmp
        while read -r ip; do [[ -n "$ip" ]] && ipset add geo_v6_tmp "$ip" 2>/dev/null; done < "$V6FILE"
        ipset swap geo_v6_tmp geo_v6
        ipset destroy geo_v6_tmp

        # 应用底层过滤规则
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
    else
        # ------ Alpine / 无ipset环境的 纯 iptables 方案 ------
        green "检测到当前环境不支持 ipset，正在自动切换为纯 iptables 模式..."
        
        # 预先生成 iptables 批量追加脚本以提高效率
        local v4_rules="/tmp/v4_rules.txt"
        local v6_rules="/tmp/v6_rules.txt"
        > $v4_rules
        > $v6_rules

        for proto in tcp udp; do
            if [[ "$MODE" == "block" ]]; then
                if [[ "$PORTS" == "all" ]]; then
                    while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto -j DROP" >> $v4_rules; done < "$V4FILE"
                    while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto -j DROP" >> $v6_rules; done < "$V6FILE"
                else
                    for p in $PORTS; do
                        while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto --dport $p -j DROP" >> $v4_rules; done < "$V4FILE"
                        while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto --dport $p -j DROP" >> $v6_rules; done < "$V6FILE"
                    done
                fi
            else
                # “只允许”模式在纯iptables下，先放行该国，最后一条规则封锁其余所有
                if [[ "$PORTS" == "all" ]]; then
                    while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto -j ACCEPT" >> $v4_rules; done < "$V4FILE"
                    while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto -j ACCEPT" >> $v6_rules; done < "$V6FILE"
                    echo "-A GEO_CHAIN -p $proto -j DROP" >> $v4_rules
                    echo "-A GEO_CHAIN -p $proto -j DROP" >> $v6_rules
                else
                    for p in $PORTS; do
                        while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto --dport $p -j ACCEPT" >> $v4_rules; done < "$V4FILE"
                        while read -r ip; do [[ -n "$ip" ]] && echo "-A GEO_CHAIN -s $ip -p $proto --dport $p -j ACCEPT" >> $v6_rules; done < "$V6FILE"
                        echo "-A GEO_CHAIN -p $proto --dport $p -j DROP" >> $v4_rules
                        echo "-A GEO_CHAIN -p $proto --dport $p -j DROP" >> $v6_rules
                    done
                fi
            fi
        done

        # 批量导入规则（避免逐条处理导致的超长耗时）
        [[ -s "$v4_rules" ]] && iptables-restore -n < <(echo "*filter"; cat $v4_rules; echo "COMMIT")
        [[ -s "$v6_rules" ]] && ip6tables-restore -n < <(echo "*filter"; cat $v6_rules; echo "COMMIT")
        rm -f $v4_rules $v6_rules
    fi

    save_rules
    green "规则已成功应用并持久化保存"
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
            read -p $'\033[32m国家代码(例如 cn us jp): \033[0m' COUNTRY
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
        WHITELIST=$(echo $WHITELIST | sed "s/\b$ip\b//g")
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
    save_rules
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
    if command -v ipset >/dev/null 2>&1; then
        ipset list | grep "^Name:"
    fi
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
    if command -v ipset >/dev/null 2>&1; then
        ipset list | grep "^Name: geo_" | awk '{print $2}' | xargs -r -I {} ipset destroy {} 2>/dev/null
    fi
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    rm -f $SCRIPT_PATH
    save_rules
    green "已彻底卸载完成"
    exit 0
}

# ================== 菜单 ==================
menu(){
    clear
    local v_mode="未配置"
    local v_country="无"
    local v_ports="无"
    if [ -f "$CONF" ]; then
        source $CONF 2>/dev/null
        [ "$MODE" == "block" ] && v_mode="${RED}仅封锁${RESET}"
        [ "$MODE" == "allow" ] && v_mode="${GREEN}仅放行${RESET}"
        [ -n "$COUNTRY" ] && v_country=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        [ -n "$PORTS" ] && v_ports="$PORTS"
    fi

    echo -e "${GREEN}===== VPS国家防火墙 =====${RESET}"
    echo -e "${BLUE}当前模式: ${v_mode}"
    echo -e "${BLUE}目标国家: ${YELLOW}${v_country}${RESET}"
    echo -e "${BLUE}受控端口: ${YELLOW}${v_ports}${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}1 添加规则${RESET}"
    echo -e "${GREEN}2 删除端口规则${RESET}"
    echo -e "${GREEN}3 查看规则详情${RESET}"
    echo -e "${GREEN}4 添加白名单${RESET}"
    echo -e "${GREEN}5 删除白名单${RESET}"
    echo -e "${GREEN}6 更新${RESET}"
    echo -e "${GREEN}7 卸载${RESET}"
    echo -e "${GREEN}0 退出${RESET}"
    echo -e "${GREEN}=========================${RESET}"
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

# 支持直接命令行静默调用（为了配合自动化 cron 更新）
if [ "$1" == "apply" ]; then
    apply_rules
    exit 0
fi

# ================== 主循环 ==================
init_env
while true; do
    menu
    read -r -p $'\033[32m按回车继续...\033[0m'
done
