#!/bin/bash
# 流媒体解锁 DNS 快捷切换脚本（无检测）

# 菜单顺序
dns_order=( "HK" "JP" "TW" "SG" "KR" "US" "UK" "DE" "RFC" "自定义" )

# DNS 列表
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

# 绿色
green="\033[32m"
reset="\033[0m"

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


    # 退出
    if [[ "$choice" == "00" ]]; then
        exit 0
    fi

    # 判断输入
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        # 自定义 DNS
        if [[ "$region" == "自定义" ]]; then
            read -p "$(echo -e ${green}请输入自定义 DNS IP 地址:${reset}) " custom_dns
            dns_to_set="$custom_dns"
        else
            dns_to_set="${dns_list[$region]}"
        fi

        # 应用 DNS
        if [[ -n "$dns_to_set" ]]; then
            echo -e "${green}正在设置 DNS 为 $dns_to_set ($region) ...${reset}"
            cp /etc/resolv.conf /etc/resolv.conf.bak
            echo "nameserver $dns_to_set" > /etc/resolv.conf
            echo -e "${green}DNS 已切换完成${reset}\n"
        fi
    else
        echo -e "${green}无效选择，请重新输入。${reset}"
    fi
done  
