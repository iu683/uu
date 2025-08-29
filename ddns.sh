#!/bin/bash
# 流媒体解锁 DNS 快捷切换脚本（无检测）

# 菜单顺序
dns_order=("Def" "HK" "JP" "TW" "SG" "US" "UK" "DE" "RFC" "自定义" "更新脚本")

# DNS 列表
declare -A dns_list=(
  ["Def"]="154.83.83.83"
  ["HK"]="154.83.83.84"
  ["JP"]="154.83.83.85"
  ["TW"]="154.83.83.86"
  ["SG"]="154.83.83.87"
  ["US"]="154.83.83.88"
  ["UK"]="154.83.83.89"
  ["DE"]="154.83.83.90"
  ["RFC"]="22.22.22.22"
  ["自定义"]="custom"
  ["更新脚本"]="update"
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
    echo -e "\n${green}[0 ] 退出${reset}\n"

    read -p "$(echo -e ${green}请输入编号:${reset}) " choice


    # 退出
    if [[ "$choice" == "0" ]]; then
        echo -e "${green}退出脚本${reset}"
        exit 0
    fi

    # 判断输入
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        # 更新脚本
        if [[ "$region" == "更新脚本" ]]; then
            echo -e "${green}正在从远程拉取并运行最新版本...${reset}"
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/unlockdns.sh)
            exit 0
        fi

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
