#!/bin/bash
# 万能 DNS 切换脚本（自动识别 resolved / resolv.conf）

dns_order=( "HK" "JP" "TW" "SG" "KR" "US" "UK" "DE" "RFC" "自定义" )

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
  ["自定义"]="custom"
)

green="\033[32m"
red="\033[31m"
reset="\033[0m"

########################################
# 检测是否为 resolved stub 模式
########################################
is_resolved_mode() {
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf | grep -q "stub-resolv.conf"; then
            return 0
        fi
    fi
    return 1
}

########################################
# 修改 resolv.conf 文件模式
########################################
set_resolvconf_dns() {

    # 检查是否锁定
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q "\-i\-"; then
        echo -e "${green}检测到 resolv.conf 已锁定，正在解锁...${reset}"
        chattr -i /etc/resolv.conf 2>/dev/null
        was_locked=true
    else
        was_locked=false
    fi

    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

    echo "nameserver $1" > /etc/resolv.conf
    echo "options timeout:2 attempts:3" >> /etc/resolv.conf

    echo -e "${green}DNS 已写入 resolv.conf${reset}"

    if $was_locked; then
        read -p "$(echo -e ${green}是否重新锁定 resolv.conf? (y/n):${reset}) " relock
        if [[ "$relock" == "y" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null
            echo -e "${green}已重新锁定${reset}"
        fi
    fi
}

########################################
# 修改 systemd-resolved 模式
########################################
set_resolved_dns() {

    interface=$(ip route | grep default | awk '{print $5}' | head -n1)

    if [[ -z "$interface" ]]; then
        echo -e "${red}无法检测网络接口${reset}"
        return
    fi

    echo -e "${green}使用 resolved 模式，接口: $interface${reset}"

    resolvectl dns "$interface" "$1"
    resolvectl flush-caches

    echo -e "${green}DNS 已通过 resolvectl 应用${reset}"
}

########################################
# 主循环
########################################
while true; do
    echo -e "${green}请选择要使用的 DNS 区域：${reset}"
    count=0
    for region in "${dns_order[@]}"; do
        ((count++))
        if [[ $count -lt 10 ]]; then
            printf "${green}[0%d] %-10s${reset}" "$count" "$region"
        else
            printf "${green}[%2d] %-10s${reset}" "$count" "$region"
        fi
        (( count % 2 == 0 )) && echo ""
    done
    echo -e "${green}[00] 退出${reset}"

    read -p "$(echo -e ${green}请输入编号:${reset}) " choice

    if [[ "$choice" == "00" ]]; then
        exit 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        if [[ "$region" == "自定义" ]]; then
            read -p "$(echo -e ${green}请输入 DNS IP:${reset}) " dns_to_set
        else
            dns_to_set="${dns_list[$region]}"
        fi

        if [[ -n "$dns_to_set" ]]; then
            echo -e "${green}正在设置 DNS 为 $dns_to_set ($region)...${reset}"

            if is_resolved_mode; then
                set_resolved_dns "$dns_to_set"
            else
                set_resolvconf_dns "$dns_to_set"
            fi

            echo
        fi
    else
        echo -e "${red}无效选择，请重新输入。${reset}"
    fi
done
