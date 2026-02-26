#!/bin/bash
# 一键系统重装脚本（分类菜单 + 编号选择 + 二次确认）
# 支持 Linux 全系列 + Windows 全系列

# 设置颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 下载脚本
download_script() {
    local type="$1"
    if [ "$type" == "MollyLau" ]; then
        wget --no-check-certificate -qO InstallNET.sh "https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh" && chmod +x InstallNET.sh
    else
        curl -O "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    fi
}

# 系统信息表：编号|系统名|分类|下载方式|用户名|密码|端口|重装命令
systems=(
"1|debian13|Debian|bin456789|root|123@@@|22|bash reinstall.sh debian 13"
"2|debian12|Debian|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -debian 12"
"3|debian11|Debian|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -debian 11"
"4|debian10|Debian|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -debian 10"
"5|ubuntu24.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 24.04"
"6|ubuntu22.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 22.04"
"7|ubuntu20.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 20.04"
"8|ubuntu18.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 18.04"
"9|rocky10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky"
"10|rocky9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky 9"
"11|alma10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux"
"12|alma9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux 9"
"13|oracle10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle"
"14|oracle9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle 9"
"15|fedora42|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora"
"16|fedora41|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora 41"
"17|centos10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 10"
"18|centos9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 9"
"19|alpine|其他Linux|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -alpine"
"20|arch|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh arch"
"21|kali|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh kali"
"22|openeuler|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh openeuler"
"23|opensuse|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh opensuse"
"24|fnos|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh fnos"
"25|windows11|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 11 -lang cn"
"26|windows10|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 10 -lang cn"
"27|windows7|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh windows --iso=\"https://drive.massgrave.dev/cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso\" --image-name='Windows 7 PROFESSIONAL'"
"28|windows2022|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2022 -lang cn"
"29|windows2019|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2019 -lang cn"
"30|windows2016|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2016 -lang cn"
"31|windows11arm|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz"
)

while true; do
    # 显示菜单
    echo -e "${GREEN}=== 一键重装系统管理菜单 ===${RESET}"

    last_category=""
    for sys in "${systems[@]}"; do
        IFS="|" read -r id name category _ _ _ _ _ <<< "$sys"
        if [[ "$category" != "$last_category" ]]; then
            echo -e "${GREEN}--- $category 系统 ---${RESET}"
            last_category="$category"
        fi
        echo -e "${YELLOW}${id}. ${name}${RESET}"
    done
    echo -e "${RED} 0. 退出${RESET}"

    # 用户选择编号
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" num_choice

    # 支持 0 或 00 退出
    if [[ "$num_choice" == "0" || "$num_choice" == "00" ]]; then
        exit 0
    fi


    found=0
    for sys in "${systems[@]}"; do
        IFS="|" read -r id name _ dl user pass port cmd <<< "$sys"
        if [[ "$num_choice" == "$id" ]]; then
            found=1
            echo -e "${YELLOW}重装后初始用户名: ${GREEN}$user${RESET}  初始密码: ${GREEN}$pass${RESET}  远程端口: ${GREEN}$port${RESET}"
            echo -e "${YELLOW}注意: 重装有风险，请提前备份重要数据！${RESET}"

            # 二次确认
            read -p "你确定要重装 ${name} 系统吗？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                download_script "$dl"
                eval "$cmd"
                echo -e "${GREEN}系统重装完成，正在重启...${RESET}"
                reboot
                break 2
            else
                echo -e "${YELLOW}已取消重装 ${name} 系统，返回菜单${RESET}"
                sleep 1
            fi
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo -e "${RED}无效编号，请重新选择！${RESET}"
    fi
done
