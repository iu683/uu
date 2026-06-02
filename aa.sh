#!/bin/bash
# 一键系统重装脚本（分类菜单 + 编号选择 + 动态交互安全版 + 支持SSH公钥）
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
        curl -sO "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" && chmod +x reinstall.sh
    fi
}

# 系统信息表：编号|系统名|分类|下载方式|默认用户名|默认密码|默认端口|重装基础命令
systems=(
"1|debian13|Debian|bin456789|root|123@@@|22|bash reinstall.sh debian 13"
"2|debian12|Debian|bin456789|root|123@@@|22|bash reinstall.sh debian 12"
"3|debian11|Debian|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -debian 11"
"4|debian10|Debian|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -debian 10"
"5|ubuntu26.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 26.04"
"6|ubuntu24.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 24.04"
"7|ubuntu22.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 22.04"
"8|ubuntu20.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 20.04"
"9|ubuntu18.04|Ubuntu|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -ubuntu 18.04"
"10|rocky10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky"
"11|rocky9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky 9"
"12|alma10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux"
"13|alma9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux 9"
"14|oracle10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle"
"15|oracle9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle 9"
"16|fedora44|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora 44"
"17|fedora43|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora 43"
"18|centos10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 10"
"19|centos9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 9"
"20|Alpine Linux|其他Linux|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -alpine"
"21|arch|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh arch"
"22|kali|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh kali"
"23|openeuler|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh openeuler"
"24|opensuseTumbleweed|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh opensuse"
"25|fnos飞牛公测版|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh fnos"
"26|windows11|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 11 -lang cn"
"27|windows10|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 10 -lang cn"
"28|windows7|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh windows --iso=\"https://drive.massgrave.dev/cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso\" --image-name='Windows 7 PROFESSIONAL'"
"29|windowsServer2025|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2025 -lang cn"
"30|windowsServer2022|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2022 -lang cn"
"31|windowsServer2019|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2019 -lang cn"
"32|windowsServer2016|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2016 -lang cn"
"33|windows11arm|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz"
)

while true; do
    # 显示菜单
    echo -e "${GREEN}=== 重装系统管理菜单 ===${RESET}"

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
        IFS="|" read -r id name category dl def_user def_pass def_port cmd <<< "$sys"
        if [[ "$num_choice" == "$id" ]]; then
            found=1
            
            echo -e "\n${RED}⚠️  警告: 此操作将会完全重装系统，磁盘上所有数据将丢失！${RESET}"
            echo -e "${RED}⚠️  请确保已备份重要数据！${RESET}"
            
            # 第一次安全确认
            read -p "$(echo -e ${RED}你确定要重装 ${name} 系统吗？(y/n): ${RESET})" confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消重装 ${name} 系统，返回菜单${RESET}"
                sleep 1
                break
            fi

            final_cmd="$cmd"

            # 核心改动：如果是 bin456789 且是 Linux 系统，触发自定义交互
            if [[ "$dl" == "bin456789" && "$category" != "Windows" && "$name" != *"dd"* ]]; then
                echo -e "\n${GREEN}--- 配置新系统凭据 ---${RESET}"
                
                # 1. 交互输入用户名
                read -p "请输入用户名 (默认 ${def_user}): " custom_user
                custom_user=${custom_user:-$def_user}

                # 2. 交互输入 SSH 公钥
                echo -e "${YELLOW}提示: 支持公钥文本、URL、github:用户名、gitlab:用户名 等${RESET}"
                read -p "请输入 SSH 公钥 (留空则使用密码登录): " custom_key

                # 3. 交互输入密码 (仅在没有输入公钥时触发)
                custom_pass=""
                if [[ -z "$custom_key" ]]; then
                    read -p "请输入 ${custom_user} 的密码: " custom_pass
                    if [[ -z "$custom_pass" ]]; then
                        echo -e "${RED}❌ 错误: 未提供公钥，且密码不能为空，操作已取消。${RESET}"
                        sleep 1
                        break
                    fi
                else
                    echo -e "${GREEN}检测到已输入公钥，重装时将不配置密码。${RESET}"
                fi

                # 4. 交互输入端口
                read -p "请输入 SSH 端口 (默认 ${def_port}): " custom_port
                custom_port=${custom_port:-$def_port}

                # 动态拼接自定义参数
                if [[ -n "$custom_key" ]]; then
                    # 使用公钥，不传 --password
                    final_cmd="$cmd --username \"$custom_user\" --ssh-key \"$custom_key\" --ssh-port \"$custom_port\""
                else
                    # 使用密码
                    final_cmd="$cmd --username \"$custom_user\" --password \"$custom_pass\" --ssh-port \"$custom_port\""
                fi
                
                # 打印最终凭据给用户核对
                echo -e "\n${YELLOW}请牢记重装后凭据:${RESET}"
                echo -e "用户名: ${GREEN}${custom_user}${RESET}  SSH端口: ${GREEN}${custom_port}${RESET}"
                if [[ -n "$custom_key" ]]; then
                    echo -e "登录方式: ${GREEN}仅限 SSH 公钥证书登录 (密码为空)${RESET}"
                else
                    echo -e "初始密码: ${GREEN}${custom_pass}${RESET}"
                fi
            else
                # MollyLau 脚本或 Windows/DD 镜像保持原样提示
                echo -e "\n${YELLOW}重装后初始用户名: ${GREEN}$def_user${RESET}  初始密码: ${GREEN}$def_pass${RESET}  远程端口: ${GREEN}$def_port${RESET}"
            fi

            # 第二次最终执行确认
            echo ""
            read -p "按 Enter 键开始下载并触发重装流程 (Ctrl+C 取消)..." dummy

            # 开始下载并执行
            echo -e "${GREEN}🔧 正在下载重装...${RESET}"
            download_script "$dl"
            
            echo -e "${GREEN}🔧 正在执行重装命令...${RESET}"
            # 执行最终拼接好的命令
            eval "$final_cmd"

            # 绿色重启提示
            echo -e "${GREEN}✔ 系统重装环境已就绪。${RESET}"
            read -p "按 Enter 键确认重启服务器并开始底层重装(Ctrl+C 取消)..." dummy
            
            echo -e "${GREEN}>>> 正在重启系统...${RESET}"
            reboot
            break 2
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo -e "${RED}无效编号，请重新选择！${RESET}"
    fi
done
