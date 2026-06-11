#!/bin/bash
# ==================================================
# VPS Geo Firewall (IPv4+IPv6)
# Alpine Linux 专属优化版 (高稳定性/生产可用)
# ==================================================

CONF="/opt/geoip/geo.conf"
UPDATE_SCRIPT="/opt/geoip/update_geo.sh"
SCRIPT_PATH="/usr/local/bin/geofirewall"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"

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

    if [[ ! -f /opt/geoip/.deps_installed ]]; then
        # 必须确保先换源或更新，并确保安装 bash 本身
        apk update
        apk add ipset iptables ip6tables curl crontabs bash sed awk

        rc-update add iptables default 2>/dev/null
        rc-update add ip6tables default 2>/dev/null
        rc-service iptables start 2>/dev/null
        rc-service ip6tables start 2>/dev/null
        
        touch /opt/geoip/.deps_installed
        green "Alpine 依赖环境（含极简 Bash）初始化成功！"
    fi
}

download_script(){
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    green "脚本已更新完成。"
}

get_my_ip(){ 
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}'
}

get_ssh_port(){
    local port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    echo "${port:-22}"
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
# 重新加载规则以应用新IP库
$SCRIPT_PATH apply_backend
EOF

chmod +x $UPDATE_SCRIPT
rc-service crond start 2>/dev/null
rc-update add crond default 2>/dev/null

(crontab -l 2>/dev/null | grep -v update_geo.sh; echo "0 3 * * * $UPDATE_SCRIPT") | crontab -
green "每日 03:00 自动动态更新 IP 库"
}

# ================== 原子更新 ipset ==================
update_ipset(){
    local SET_NAME=$1
    local FILE=$2
    local FAMILY=$3

    [[ ! -s "$FILE" ]] && { red "错误: IP库文件为空或下载失败: $FILE"; return 1; }

    ipset create $SET_NAME hash:net family $FAMILY -exist
    ipset create ${SET_NAME}_tmp hash:net family $FAMILY -exist
    ipset flush ${SET_NAME}_tmp

    # 规范化读取，去除 Windows 回车符等干扰
    while read -r ip || [[ -n "$ip" ]]; do
        ip=$(echo "$ip" | tr -d '\r' | xargs)
        [[ -n "$ip" && ! "$ip" =~ ^# ]] && ipset add ${SET_NAME}_tmp "$ip" 2>/dev/null
    done < "$FILE"

    ipset swap ${SET_NAME}_tmp $SET_NAME
    ipset destroy ${SET_NAME}_tmp
    return 0
}

save_rules(){
    rc-service iptables save >/dev/null 2>&1
    rc-service ip6tables save >/dev/null 2>&1
}

# ================== 应用规则核心 ==================
apply_rules(){
    source $CONF 2>/dev/null
    [[ -z "$COUNTRY" ]] && { red "未检测到有效配置"; return; }

    SSH_PORT=$(get_ssh_port)
    green "自动保护并放行本服务器 SSH 端口: $SSH_PORT"

    # 重置独立链
    iptables -X GEO_CHAIN 2>/dev/null
    ip6tables -X GEO_CHAIN 2>/dev/null
    iptables -N GEO_CHAIN 2>/dev/null
    ip6tables -N GEO_CHAIN 2>/dev/null

    # 确保 INPUT 链第一级拦截跳转
    iptables -C INPUT -j GEO_CHAIN 2>/dev/null || iptables -I INPUT 1 -j GEO_CHAIN
    ip6tables -C INPUT -j GEO_CHAIN 2>/dev/null || ip6tables -I INPUT 1 -j GEO_CHAIN

    # 1. 基础放行规则（状态防火墙）
    iptables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A GEO_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A GEO_CHAIN -i lo -j ACCEPT
    ip6tables -A GEO_CHAIN -i lo -j ACCEPT

    # 2. 强力白名单放行（放在最前，防止被误杀）
    MYIP=$(get_my_ip)
    [[ -n "$MYIP" ]] && iptables -A GEO_CHAIN -s $MYIP -j ACCEPT
    for ip in $WHITELIST; do
        if [[ "$ip" =~ : ]]; then
            ip6tables -A GEO_CHAIN -s $ip -j ACCEPT
        else
            iptables -A GEO_CHAIN -s $ip -j ACCEPT
        fi
    done

    # 3. 下载并装载 ipset
    CC_L=$(echo $COUNTRY | tr A-Z a-z)
    V4FILE="/opt/geoip/${CC_L}.zone"
    V6FILE="/opt/geoip/${CC_L}.ipv6.zone"

    mkdir -p /opt/geoip
    [[ ! -f $V4FILE || ! -s $V4FILE ]] && curl -s -o $V4FILE https://www.ipdeny.com/ipblocks/data/countries/$CC_L.zone
    [[ ! -f $V6FILE || ! -s $V6FILE ]] && curl -s -o $V6FILE https://www.ipdeny.com/ipv6/ipaddresses/aggregated/$CC_L-aggregated.zone

    update_ipset geo_v4 $V4FILE inet
    update_ipset geo_v6 $V6FILE inet6

    # 4. 根据模式应用策略
    # 如果是放行特定国家，但是全端口放行，为了防止把自己锁在外面，默认对全球放行 SSH
    if [[ "$MODE" == "allow" && "$PORTS" == "all" ]]; then
        iptables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
        ip6tables -A GEO_CHAIN -p tcp --dport $SSH_PORT -j ACCEPT
    fi

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
            # allow 模式下特定端口控制
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

    save_rules
    green "Geo 防火墙策略已成功矩阵化应用！"
}

write_config(){
    echo "MODE=\"$MODE\"" > $CONF
    echo "COUNTRY=\"$COUNTRY\"" >> $CONF
    echo "PORTS=\"$PORTS\"" >> $CONF
    echo "WHITELIST=\"$WHITELIST\"" >> $CONF
}

# ================== 菜单交互 ==================
add_rule(){
    echo -e "${GREEN}选择模式:${RESET}"
    echo -e "${GREEN}1 封锁某国某端口${RESET}"
    echo -e "${GREEN}2 封锁某国所有端口${RESET}"
    echo -e "${GREEN}3 只允许某国某端口${RESET}"
    echo -e "${GREEN}4 只允许某国访问整个服务器 (非该国IP将无法连接除SSH外的其余端口)${RESET}"
    read -p "选择模式(1-4): " choice

    case "$choice" in
        1)
            MODE="block"
            read -p "国家代码(小写，如 cn, us, jp): " COUNTRY
            read -p "端口 (多个用空格隔开): " PORTS
            ;;
        2)
            MODE="block"
            read -p "国家代码(小写，如 cn, us, jp): " COUNTRY
            PORTS="all"
            ;;
        3)
            MODE="allow"
            read -p "国家代码(小写，如 cn, us, jp): " COUNTRY
            read -p "端口 (多个用空格隔开): " PORTS
            ;;
        4)
            MODE="allow"
            read -p "国家代码(小写，如 cn, us, jp): " COUNTRY
            PORTS="all"
            ;;
        *)
            red "无效选择"
            return
            ;;
    esac

    write_config
    install_auto_update
    apply_rules
}

add_whitelist(){
    read -p "输入要添加的白名单 IP (多个用空格隔开): " ips
    source $CONF 2>/dev/null
    WHITELIST="$WHITELIST $ips"
    write_config
    apply_rules
}

delete_whitelist(){
    read -p "输入要删除的白名单 IP (多个用空格隔开): " ips
    source $CONF 2>/dev/null
    for ip in $ips; do
        WHITELIST=$(echo $WHITELIST | sed -E "s/\b$ip\b//g")
    done
    write_config
    apply_rules
}

delete_rules(){
    source $CONF 2>/dev/null
    [[ -z "$PORTS" ]] && { red "当前未配置任何受控端口"; return; }
    echo -e "当前受控端口为: ${GREEN}$PORTS${RESET}"
    read -p "输入要移除受控的端口 (多个用空格隔开): " DEL_PORTS
    [[ -z "$DEL_PORTS" ]] && { red "未输入任何端口"; return; }
    
    for p in $DEL_PORTS; do
        PORTS=$(echo $PORTS | sed -E "s/\b$p\b//g")
    done
    # 如果过滤后端口为空，切回 all 或者清空
    [[ -z $(echo $PORTS | xargs) ]] && PORTS="all"
    
    write_config
    apply_rules
    green "选定端口已移出监控配置。"
}

view_rules(){
    clear
    green "========= 核心配置文件 ========="
    cat $CONF 2>/dev/null
    echo
    green "========= IPv4 规则链 (GEO_CHAIN) ========="
    iptables -L GEO_CHAIN -n --line-numbers 2>/dev/null
    echo
    green "========= IPv6 规则链 (GEO_CHAIN) ========="
    ip6tables -L GEO_CHAIN -n --line-numbers 2>/dev/null
    echo
    green "========= 活性 IPSet 集合 ========="
    ipset list | grep -E "^Name:|^Type:|^Elements:"
}

uninstall_all(){
    green "正在完全卸载防火墙并清理环境..."
    iptables -D INPUT -j GEO_CHAIN 2>/dev/null
    ip6tables -D INPUT -j GEO_CHAIN 2>/dev/null
    iptables -F GEO_CHAIN 2>/dev/null
    ip6tables -F GEO_CHAIN 2>/dev/null
    iptables -X GEO_CHAIN 2>/dev/null
    ip6tables -X GEO_CHAIN 2>/dev/null
    ipset destroy geo_v4 2>/dev/null
    ipset destroy geo_v6 2>/dev/null
    rm -rf /opt/geoip
    crontab -l 2>/dev/null | grep -v update_geo.sh | crontab -
    rm -f $SCRIPT_PATH
    save_rules
    green "卸载完成，系统防火墙已恢复默认状态。"
    exit 0
}

menu(){
    clear
    local v_mode="未配置"
    local v_country="无"
    local v_ports="无"
    if [ -f "$CONF" ]; then
        source $CONF 2>/dev/null
        [ "$MODE" == "block" ] && v_mode="${RED}仅封锁(Blacklist)${RESET}"
        [ "$MODE" == "allow" ] && v_mode="${GREEN}仅放行(Whitelist)${RESET}"
        [ -n "$COUNTRY" ] && v_country=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        [ -n "$PORTS" ] && v_ports="$PORTS"
    fi

    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}   ◈   国家IP防火墙   ◈  ${RESET}"
    echo -e "${GREEN}=========================${RESET}"
    echo -e "${GREEN}当前模式: ${v_mode}"
    echo -e "${GREEN}目标国家: ${v_country}${RESET}"
    echo -e "${GREEN}受控端口: ${v_ports}${RESET}"
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

# 后台静默调用入口（防止 crontab 执行时弹出菜单）
if [[ "$1" == "apply_backend" ]]; then
    apply_rules
    exit 0
fi

# ================== 主循环 ==================
init_env
while true; do
    menu
    read -r -p "按回车键继续..."
done
