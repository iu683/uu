#!/bin/bash
# 万能 DNS 切换脚本（增强版，支持恢复默认 DNS + 当前 DNS 显示 + 可锁定 /etc/resolv.conf）

dns_order=( "HK" "JP" "TW" "SG" "KR" "US" "UK" "DE" "RFC" "自定义" "恢复默认DNS" )

declare -A dns_list=(
  ["HK"]="154.83.83.83"
  ["JP"]="45.76.215.40"
  ["TW"]="154.83.83.86"
  ["SG"]="149.28.158.78"
  ["KR"]="158.247.223.218"
  ["US"]="66.42.97.127"
  ["UK"]="45.32.179.189"
  ["DE"]="80.240.28.27"
  ["RFC"]="22.22.22.22"
)

green="\033[32m"
red="\033[31m"
yellow="\033[33m"
reset="\033[0m"

########################################
# 判断是否 Ubuntu
########################################
is_ubuntu() {
    [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release
}

########################################
# 判断是否启用 systemd-resolved stub
########################################
is_resolved_mode() {
    if ! systemctl is-active systemd-resolved >/dev/null 2>&1; then
        return 1
    fi
    if [ -L /etc/resolv.conf ]; then
        target=$(readlink -f /etc/resolv.conf)
        echo "$target" | grep -q "systemd/resolve" && return 0
    fi
    return 1
}

########################################
# 显示当前 DNS 状态
########################################
show_current_dns() {
    echo -e "${yellow}===== 当前 DNS 状态 =====${reset}"

    if is_ubuntu && is_resolved_mode; then
        resolvectl status | awk '/Current DNS Server|DNS Servers/ {print $0}'
    else
        if [ -f /etc/resolv.conf ]; then
            grep -E "nameserver" /etc/resolv.conf
        else
            echo -e "${red}未检测到 /etc/resolv.conf${reset}"
        fi
    fi
    echo ""
}

########################################
# 写入 resolv.conf（支持锁定）
########################################
write_resolv_conf() {
    DNS1=$1
    DNS2=$2
    was_locked=false

    if lsattr /etc/resolv.conf 2>/dev/null | grep -q "\-i\-"; then
        echo -e "${yellow}检测到 /etc/resolv.conf 已锁定，正在解锁...${reset}"
        chattr -i /etc/resolv.conf 2>/dev/null
        was_locked=true
    fi

    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

    echo "nameserver $DNS1" > /etc/resolv.conf
    echo "nameserver $DNS2" >> /etc/resolv.conf
    echo "options timeout:2 attempts:3" >> /etc/resolv.conf

    echo -e "${green}DNS 已写入 /etc/resolv.conf${reset}"

    if [ "$was_locked" = true ]; then
        echo -ne "${green}是否重新锁定 /etc/resolv.conf? (y/n) [默认 y]:${reset} "
        read relock
        relock=${relock:-y}
        if [[ "$relock" == "y" || "$relock" == "Y" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null
            echo -e "${green}/etc/resolv.conf 已重新锁定${reset}"
        fi
    fi
}

########################################
# 临时 resolvectl 模式
########################################
set_resolved_runtime_dns() {
    DNS1=$1
    DNS2=$2
    interface=$(ip route | awk '/default/ {print $5; exit}')
    if [ -z "$interface" ]; then
        echo -e "${red}无法检测网络接口${reset}"
        return
    fi
    resolvectl dns "$interface" "$DNS1"
    resolvectl dns "$interface" "$DNS2"
    resolvectl flush-caches
    echo -e "${green}DNS 已通过 resolvectl 临时应用${reset}"
}

########################################
# Ubuntu 默认 DNS 恢复（始终启用 systemd-resolved）
########################################
restore_ubuntu_default_dns() {
    DNS1="8.8.8.8"
    DNS2="1.1.1.1"

    echo -e "${green}正在恢复 Ubuntu 默认 DNS 设置...${reset}"

    systemctl enable systemd-resolved
    systemctl start systemd-resolved

    # 恢复 resolv.conf symlink
    [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ] && rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    # 注释掉 resolved.conf 自定义 DNS
    sed -i "s/^\s*DNS=.*/#DNS=/" /etc/systemd/resolved.conf
    sed -i "s/^\s*FallbackDNS=.*/#FallbackDNS=/" /etc/systemd/resolved.conf

    systemctl restart systemd-resolved
    resolvectl flush-caches

    echo -e "${green}Ubuntu 默认 DNS 已恢复完成${reset}"
}

########################################
# 恢复默认 DNS（自动识别 Ubuntu/Debian）
########################################
restore_default_dns() {
    if is_ubuntu; then
        restore_ubuntu_default_dns
    else
        write_resolv_conf "8.8.8.8" "1.1.1.1"
    fi
}

########################################
# 主循环
########################################
while true; do
    show_current_dns

    echo -e "${green}请选择要使用的 DNS 区域：${reset}"
    count=0
    for region in "${dns_order[@]}"; do
        ((count++))
        printf "${green}[%02d] %-15s${reset}" "$count" "$region"
        (( count % 2 == 0 )) && echo ""
    done
    echo -e "${green}[00] 退出${reset}"

    echo -ne "${green}请输入编号:${reset} "
    read choice
    [ "$choice" = "00" ] && exit 0

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        if [[ "$region" == "自定义" ]]; then
            echo -ne "${green}请输入 DNS IP（空格分隔两个）:${reset} "
            read dns_to_set
            dns_arr=($dns_to_set)
            DNS1=${dns_arr[0]}
            DNS2=${dns_arr[1]:-"1.1.1.1"}
        elif [[ "$region" == "恢复默认DNS" ]]; then
            restore_default_dns
            continue
        else
            DNS1="${dns_list[$region]}"
            DNS2="1.1.1.1"
        fi

        echo -e "${green}正在设置 DNS 为 $DNS1 $DNS2 ($region)...${reset}"

        if is_ubuntu; then
            # Ubuntu 始终使用 resolved
            systemctl enable systemd-resolved
            systemctl start systemd-resolved
            # 写入 resolved.conf
            sed -i "s/^\s*DNS=.*/DNS=$DNS1/" /etc/systemd/resolved.conf
            sed -i "s/^\s*FallbackDNS=.*/FallbackDNS=$DNS2/" /etc/systemd/resolved.conf
            systemctl restart systemd-resolved
            resolvectl flush-caches
        elif is_resolved_mode; then
            set_resolved_runtime_dns "$DNS1" "$DNS2"
        else
            write_resolv_conf "$DNS1" "$DNS2"
        fi

        echo
    else
        echo -e "${red}无效选择，请重新输入。${reset}"
    fi
done
