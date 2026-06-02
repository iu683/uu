#!/bin/bash
# 一键系统重装脚本（分类菜单 + 编号选择 + 动态交互安全版 + 支持SSH公钥）
# 支持 Linux 全系列 + Windows 全系列

# 设置颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 自动检测并安装基础依赖 (curl, wget, openssl)
install_dependencies() {
    local deps=("curl" "wget" "openssl")
    local missing_deps=()

    # 检查哪些工具缺失
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    # 如果没有缺失的工具，直接跳过
    if [ ${#missing_deps[@]} -eq 0 ]; then
        return 0
    fi

    echo -e "${YELLOW}发现缺失依赖: ${missing_deps[*]}，正在自动安装...${RESET}"

    # 识别包管理器并安装
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y "${missing_deps[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing_deps[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing_deps[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing_deps[@]}"
    else
        echo -e "${RED}❌ 错误: 未知系统架构，无法自动安装依赖 ${missing_deps[*]}，请手动安装后重试。${RESET}"
        exit 1
    fi
}

# 运行依赖检查
install_dependencies

# 随机密码生成函数（生成12位包含大小写字母和数字的随机密码）
generate_random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 9 | tr -d '+/' | cut -c1-12
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12
    fi
}

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
"3|debian11|Debian|bin456789|root|123@@@|22|bash reinstall.sh debian 11"
"4|debian10|Debian|bin456789|root|123@@@|22|bash reinstall.sh debian 10"
"5|ubuntu26.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 26.04"
"6|ubuntu24.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 24.04"
"7|ubuntu22.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 22.04"
"8|ubuntu20.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 20.04"
"9|ubuntu18.04|Ubuntu|bin456789|root|123@@@|22|bash reinstall.sh ubuntu 18.04"
"10|Alpine3.23|Alpine|bin456789|root|123@@@|22|bash reinstall.sh alpine 3.23"
"11|Alpine3.22|Alpine|bin456789|root|123@@@|22|bash reinstall.sh alpine 3.22"
"12|Alpine3.21|Alpine|bin456789|root|123@@@|22|bash reinstall.sh alpine 3.21"
"13|Alpine3.20|Alpine|bin456789|root|123@@@|22|bash reinstall.sh alpine 3.20"
"14|AlpineEdge|Alpine|MollyLau|root|LeitboGi0ro|22|bash InstallNET.sh -alpine"
"15|rocky10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky"
"16|rocky9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh rocky 9"
"17|alma10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux"
"18|alma9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh almalinux 9"
"19|oracle10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle"
"20|oracle9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh oracle 9"
"21|fedora44|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora 44"
"22|fedora43|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh fedora 43"
"23|centos10|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 10"
"24|centos9|RedHat系|bin456789|root|123@@@|22|bash reinstall.sh centos 9"
"25|arch|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh arch"
"26|kali|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh kali"
"27|openeuler|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh openeuler"
"28|opensuseTumbleweed|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh opensuse"
"29|fnos飞牛公测版|其他Linux|bin456789|root|123@@@|22|bash reinstall.sh fnos"
"30|windows11|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 11 -lang cn"
"31|windows10|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 10 -lang cn"
"32|windows7|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh windows --iso=\"https://drive.massgrave.dev/cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso\" --image-name='Windows 7 PROFESSIONAL'"
"33|windowsServer2025|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2025 -lang cn"
"34|windowsServer2022|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2022 -lang cn"
"35|windowsServer2019|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2019 -lang cn"
"36|windowsServer2016|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2016 -lang cn"
"37|windows11arm|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz"
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
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read num_choice

    # 支持 0 或 00 退出
    if [[ "$num_choice" == "0" || "$num_choice" == "00" ]]; then
        exit 0
    fi

    found=0
    for sys in "${systems[@]}"; do
        IFS="|" read -r id name category dl def_user def_pass def_port cmd <<< "$sys"
        if [[ "$num_choice" == "$id" ]]; then
            found=1
            
            echo -e "${YELLOW}警告: 此操作将会完全重装系统，磁盘上所有数据将丢失！${RESET}"
            echo -e "${YELLOW}请确保已备份重要数据！${RESET}"
            

            echo -ne "${YELLOW}你确定要重装 ${name} 系统吗？(y/n): ${RESET}"
            read confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消重装 ${name} 系统，返回菜单${RESET}"
                sleep 1
                break
            fi

            final_cmd="$cmd"

            # 如果是 bin456789 且是 Linux 系统，触发自定义交互
            if [[ "$dl" == "bin456789" && "$category" != "Windows" && "$name" != *"dd"* ]]; then
                echo -e "\n${GREEN}--- 配置新系统凭据 ---${RESET}"
                
                # 1. 交互输入用户名
                read -p "请输入用户名 (默认 ${def_user}): " custom_user
                custom_user=${custom_user:-$def_user}

                # 2. 交互输入 SSH 公钥
                echo -e "${YELLOW}提示: 支持公钥文本、URL、github:用户名、gitlab:用户名等${RESET}"
                echo -e "${YELLOW}例如: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIfueBkiS7BPBXMoW6RWvoDE995J61bv6xxYlD6yP3kD root@localhost${RESET}"
                read -p "请输入 SSH 公钥 (留空则使用密码登录): " custom_key

                # 3. 交互输入密码 (仅在没有输入公钥时触发)
                custom_pass=""
                if [[ -z "$custom_key" ]]; then
                    # 在这里动态生成随机密码
                    rand_pass=$(generate_random_password)
                    read -p "请输入 ${custom_user} 的密码 (直接回车随机生成: ${rand_pass}): " custom_pass
                    custom_pass=${custom_pass:-$rand_pass}
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
                    echo -e "登录方式: ${GREEN}仅限 SSH 公钥证书登录${RESET}"
                else
                    echo -e "初始密码: ${RED}${custom_pass}${RESET}  (请复制保存！)"
                fi
            else
                # MollyLau 脚本或 Windows/DD 镜像保持原样提示
                echo -e "\n${YELLOW}重装后初始用户名: ${GREEN}$def_user${RESET}  初始密码: ${GREEN}$def_pass${RESET}  远程端口: ${GREEN}$def_port${RESET}"
            fi

            # 第二次最终执行确认
            echo ""
            read -p "按回车键开始下载并触发重装流程 (Ctrl+C取消)..." dummy

            # 开始下载并执行
            echo -e "${GREEN}🔧 正在下载重装...${RESET}"
            download_script "$dl"
            
            echo -e "${GREEN}🔧 正在执行重装命令...${RESET}"
            # 执行最终拼接好的命令
            eval "$final_cmd"

            # 绿色重启提示
            echo -e "${GREEN}✔ 系统重装环境已就绪。${RESET}"
            read -p "按回车键确认重启服务器并开始底层重装(Ctrl+C取消)..." dummy
            
            echo -e "${GREEN}>>> 正在重启系统...${RESET}"
            reboot
            break 2
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo -e "${RED}无效编号，请重新选择！${RESET}"
    fi
done
