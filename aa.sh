#!/bin/bash
# =========================================================================
# 一键系统重装脚本（跨平台极致兼容通用版）
# 支持 Linux 全系列 + Windows 全系列
# =========================================================================

# 设置颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"


# 【核心修复】跨平台通用依赖检查（抛弃非标数组，完美兼容 Alpine sh）
install_dependencies() {
    local missing_deps=""
    
    # 用最传统稳健的空格字符串替代数组
    for dep in curl wget openssl; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    # 去除首尾空格
    missing_deps=$(echo "$missing_deps" | sed 's/^ *//;s/ *$//')

    if [ -z "$missing_deps" ]; then
        return 0
    fi

    echo -e "${YELLOW}🔧 发现缺失依赖: ${missing_deps}，正在自动安装...${RESET}"

    # 识别包管理器并全自动打补丁
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache $missing_deps
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y $missing_deps
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $missing_deps
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $missing_deps
    else
        echo -e "${RED}❌ 错误: 未知系统包管理器，请手动安装 [ ${missing_deps} ] 后重试。${RESET}"
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
        tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 12
    fi
}


GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    ''https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)


download_script() {
    local type="$1"
    local raw_url=""
    local file_name=""

    if [ "$type" = "MollyLau" ]; then
        file_name="InstallNET.sh"
        raw_url="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
    else
        file_name="reinstall.sh"
        raw_url="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    fi

    # 遍历 Bash 数组
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_url="${proxy}${raw_url}"
        rm -f "$file_name"
        
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW}📡 正在尝试直连下载...${RESET}"
        else
            echo -e "${YELLOW}🔄 正在尝试代理节点: ${proxy}${RESET}"
        fi

        if command -v wget >/dev/null 2>&1; then
            wget --no-check-certificate --timeout=3 --tries=1 -qO "$file_name" "$proxy_url" && chmod +x "$file_name"
        else
            if [ -z "$proxy" ]; then
                curl -m 3 -sO "$proxy_url" && chmod +x "$file_name"
            else
                curl -m 3 -sL -o "$file_name" "$proxy_url" && chmod +x "$file_name"
            fi
        fi

        # 判断是否成功
        if [ -f "$file_name" ] && [ -s "$file_name" ]; then
            echo -e "${GREEN}✅ 下载成功！${RESET}"
            return 0
        fi
    done

    echo -e "${RED}❌ 错误: 尝试了所有代理节点，均无法下载重装内核！${RESET}"
    exit 1
}

# 系统核心数据库表
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
"32|windows7|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh windows --iso=\"https://download.testip.xyz/windows/cn_windows_7_professional_with_sp1_vl_build_x64_dvd_u_677816.iso\" --image-name='Windows 7 PROFESSIONAL'"
"33|windowsServer2025|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2025 -lang cn"
"34|windowsServer2022|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2022 -lang cn"
"35|windowsServer2019|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2019 -lang cn"
"36|windowsServer2016|Windows|MollyLau|Administrator|Teddysun.com|3389|bash InstallNET.sh -windows 2016 -lang cn"
"37|windows11ARM|Windows|bin456789|Administrator|123@@@|3389|bash reinstall.sh dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz"
)

# 主循环面板
while true; do
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}        ◈  系统重装管理菜单  ◈         ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    # 渲染动态分类菜单
    last_category=""
    for sys in "${systems[@]}"; do
        
        id=$(echo "$sys" | cut -d'|' -f1)
        name=$(echo "$sys" | cut -d'|' -f2)
        category=$(echo "$sys" | cut -d'|' -f3)
        
        if [ "$category" != "$last_category" ]; then
            echo -e "${GREEN}--- ❖ $category 系统 ❖ ---${RESET}"
            last_category="$category"
        fi
        
        
        printf "${YELLOW}  %2d) %-22s${RESET}\n" "$id" "$name"
    done
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${RED}   0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    echo -ne "${GREEN}请输入你想要重装的系统编号: ${RESET}"
    read -r num_choice

    if [ "$num_choice" = "0" ] || [ "$num_choice" = "00" ] || [ -z "$num_choice" ]; then
        exit 0
    fi

    found=0
    for sys in "${systems[@]}"; do
        # 解构获取单行数据
        id=$(echo "$sys" | cut -d'|' -f1)
        
        if [ "$num_choice" = "$id" ]; then
            found=1
            
            # 提取各项参数
            name=$(echo "$sys" | cut -d'|' -f2)
            category=$(echo "$sys" | cut -d'|' -f3)
            dl=$(echo "$sys" | cut -d'|' -f4)
            def_user=$(echo "$sys" | cut -d'|' -f5)
            def_pass=$(echo "$sys" | cut -d'|' -f6)
            def_port=$(echo "$sys" | cut -d'|' -f7)
            cmd=$(echo "$sys" | cut -d'|' -f8)

            echo -e "\n${RED}  💥 极度高危警告：${RESET}"
            echo -e "${RED}您当前选择的操作将会彻底抹除整台服务器的硬盘，所有数据将灰飞烟灭！${RESET}"
            echo -e "${YELLOW}请务必确认已经离线备份了您的所有核心资产数据！${RESET}"
            echo ""
            echo -ne "${YELLOW}确定要对这台机器重装，强制重装为 [ ${name} ] 吗？(y/n): ${RESET}"
            read -r confirm
            
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}正在取消重装，返回主菜单...${RESET}"
                sleep 1.5
                break
            fi

            final_cmd="$cmd"

            # 针对 bin456789 且非 Windows 系统的自定义凭据交互
            if [ "$dl" = "bin456789" ] && [ "$category" != "Windows" ] && [[ "$name" != *"dd"* ]]; then
                echo -e "\n${GREEN}--- 👤 配置新系统登录凭据 ---${RESET}"
                
                # 初始化/清空旧循环的残存变量，防止变量污染
                custom_user="" custom_key="" custom_pass="" custom_port=""

                read -r -p "请输入用户名 (直接回车默认: ${def_user}): " custom_user
                custom_user=${custom_user:-$def_user}

                echo -e "${YELLOW}提示: 密钥支持 公钥字符串、URL、github:用户名、gitlab:用户名${RESET}"
                echo -e "${YELLOW}例如: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPYYSr25hwiXYTbVBlSzNNiYHl6vCD8CJWG70rTU+6qj2T root@localhost${RESET}"
                read -r -p "请输入 SSH 公钥 (留空则代表使用密码登录): " custom_key

                if [ -z "$custom_key" ]; then
                    # 动态生成随机密码
                    rand_pass=$(generate_random_password)
                    read -r -p "请输入登录密码 (直接回车为您随机生成: ${rand_pass}): " custom_pass
                    custom_pass=${custom_pass:-$rand_pass}
                else
                    echo -e "${GREEN}✓ 检测到您输入了公钥，系统将默认关闭密码登录，大幅增强安全性！${RESET}"
                fi

                read -r -p "请输入自定义 SSH 端口号 (直接回车默认: ${def_port}): " custom_port
                custom_port=${custom_port:-$def_port}

                # 动态科学拼接命令
                if [ -n "$custom_key" ]; then
                    final_cmd="$cmd --username \"$custom_user\" --ssh-key \"$custom_key\" --ssh-port \"$custom_port\""
                else
                    final_cmd="$cmd --username \"$custom_user\" --password \"$custom_pass\" --ssh-port \"$custom_port\""
                fi
                
                # 打印最终核对看板
                echo -e "\n${YELLOW}=======================================${RESET}"
                echo -e "${YELLOW}      📌 请截图或复制保存新系统凭据     ${RESET}"
                echo -e "${YELLOW}=======================================${RESET}"
                echo -e " 目标系统 : ${GREEN}${name}${RESET}"
                echo -e " 用户名   : ${GREEN}${custom_user}${RESET}"
                echo -e " SSH端口  : ${GREEN}${custom_port}${RESET}"
                if [ -n "$custom_key" ]; then
                    echo -e " 登录验证 : ${GREEN}仅限私钥证书配对登录${RESET}"
                else
                    echo -e " 初始密码 : ${RED}${custom_pass}${RESET}"
                fi
                echo -e "${YELLOW}=======================================${RESET}"
            else
                # MollyLau 或 Windows 保持默认配置提示
                echo -e "\n${YELLOW}📌 重装就绪凭据：用户名: ${GREEN}$def_user${RESET} | 初始密码: ${GREEN}$def_pass${RESET} | 远程端口: ${GREEN}$def_port${RESET}"
            fi

            echo ""
            read -r -p "👉 确认无误？按 [回车键] 开始自动下载重装内核文件 (Ctrl+C 取消)..." dummy

            echo -e "\n${GREEN}🚀 正在从上游源安全拉取重装驱动内核...${RESET}"
            download_script "$dl"
            
            echo -e "${GREEN}⚙️ 正在向内核注入重装指令参数...${RESET}"
            eval "$final_cmd"

            echo -e "\n${GREEN}✔ 系统重装环境已就绪！${RESET}"
            read -r -p "按 [回车键] 将立即强制重启服务器进行底层安装 (此时断开连接属于正常现象)..." dummy
            
            echo -e "${GREEN}>>> 正在重启...${RESET}"
            reboot
            exit 0
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo -e "${RED}❌ 错误：无效编号，请重新输入正确的系统选项！${RESET}"
        sleep 1.5
    fi
done
