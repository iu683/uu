#!/bin/bash
# 万能 DNS 切换脚本（Ubuntu 自动关闭 resolved + 可锁定）

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
)

green="\033[32m"
red="\033[31m"
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
    systemctl is-active systemd-resolved >/dev/null 2>&1
}

########################################
# 修改 resolv.conf 文件模式（可锁定）
########################################
set_resolvconf_dns() {
    # 解锁
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q "\-i\-"; then
        echo -e "${green}检测到 resolv.conf 已锁定，正在解锁...${reset}"
        sudo chattr -i /etc/resolv.conf
    fi

    sudo cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

    sudo bash -c "cat > /etc/resolv.conf <<EOF
nameserver $1
options timeout:2 attempts:3
EOF"

    echo -e "${green}DNS 已写入 resolv.conf${reset}"

    # 可选锁定
    echo -ne "${green}是否锁定 /etc/resolv.conf 防止被覆盖? (y/n):${reset} "
    read lock_choice
    if [[ "$lock_choice" == "y" ]]; then
        sudo chattr +i /etc/resolv.conf
        echo -e "${green}/etc/resolv.conf 已锁定${reset}"
    fi
}

########################################
# 关闭 Ubuntu resolved 并写入 resolv.conf（可锁定）
########################################
disable_ubuntu_resolved() {
    echo -e "${green}检测到 Ubuntu + systemd-resolved，正在关闭...${reset}"
    sudo systemctl stop systemd-resolved
    sudo systemctl disable systemd-resolved

    sudo rm -f /etc/resolv.conf

    sudo bash -c "cat > /etc/resolv.conf <<EOF
nameserver $1
nameserver 1.1.1.1
options timeout:2 attempts:3
EOF"

    echo -e "${green}resolved 已关闭，DNS 已写入 /etc/resolv.conf${reset}"

    # 可选锁定
    echo -ne "${green}是否锁定 /etc/resolv.conf 防止被覆盖? (y/n):${reset} "
    read lock_choice
    if [[ "$lock_choice" == "y" ]]; then
        sudo chattr +i /etc/resolv.conf
        echo -e "${green}/etc/resolv.conf 已锁定${reset}"
    fi
}

########################################
# 临时 resolvectl 模式
########################################
set_resolved_runtime_dns() {
    interface=$(ip route | awk '/default/ {print $5; exit}')
    if [ -z "$interface" ]; then
        echo -e "${red}无法检测网络接口${reset}"
        return
    fi
    sudo resolvectl dns "$interface" "$1"
    sudo resolvectl flush-caches
    echo -e "${green}DNS 已通过 resolvectl 临时应用${reset}"
}

########################################
# 主循环
########################################
while true; do
    echo -e "${green}请选择要使用的 DNS 区域：${reset}"
    count=0
    for region in "${dns_order[@]}"; do
        ((count++))
        printf "${green}[%02d] %-10s${reset}" "$count" "$region"
        (( count % 2 == 0 )) && echo ""
    done
    echo -e "${green}[00] 退出${reset}"

    echo -ne "${green}请输入编号:${reset} "
    read choice

    [ "$choice" = "00" ] && exit 0

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        if [ "$region" = "自定义" ]; then
            echo -ne "${green}请输入 DNS IP:${reset} "
            read dns_to_set
        else
            dns_to_set="${dns_list[$region]}"
        fi

        echo -e "${green}正在设置 DNS 为 $dns_to_set ($region)...${reset}"

        # 核心逻辑
        if is_ubuntu && is_resolved_mode; then
            disable_ubuntu_resolved "$dns_to_set"
        elif is_resolved_mode; then
            set_resolved_runtime_dns "$dns_to_set"
        else
            set_resolvconf_dns "$dns_to_set"
        fi

        echo
    else
        echo -e "${red}无效选择，请重新输入。${reset}"
    fi
done
