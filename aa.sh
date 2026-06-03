#!/bin/bash
# 万能 DNS 切换管理面板（支持 Ubuntu / Debian / Alpine）

dns_order=( "HK" "JP" "TW" "SG" "KR" "US" "UK" "DE" "SB" "RFC" "NHK" "自定义" )

declare -A dns_list=(
  ["HK"]="154.83.83.83"
  ["JP"]="45.76.215.40"
  ["TW"]="154.83.83.86"
  ["SG"]="149.28.158.78"
  ["KR"]="158.247.223.218"
  ["US"]="66.42.97.127"
  ["UK"]="45.32.179.189"
  ["DE"]="80.240.28.27"
  ["SB"]="6.6.6.6"
  ["RFC"]="22.22.22.22"
  ["NHK"]="151.247.88.3"
)

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
RESET="\033[0m"
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# 检查是否为root用户
if [[ $(whoami) != "root" ]]; then
    echo -e "${Error}请以root身份执行该脚本！"
    exit 1
fi

########################################
# 判断系统类型与状态
########################################
is_ubuntu() {
    [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release
}

is_alpine() {
    [ -f /etc/os-release ] && grep -qi alpine /etc/os-release
}

is_resolved_mode() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active systemd-resolved >/dev/null 2>&1
    else
        false
    fi
}

get_current_dns() {
    if [ -f /etc/resolv.conf ]; then
        # 提取第一个 nameserver
        local current
        current=$(grep -m 1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
        echo "${current:-未知}"
    else
        echo "无 resolv.conf"
    fi
}

get_lock_status() {
    if command -v lsattr &>/dev/null; then
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
            echo -e "${RED}已锁定 (i)${RESET}"
        else
            echo -e "${GREEN}未锁定${RESET}"
        fi
    else
        echo -e "${YELLOW}不支持检测${RESET}"
    fi
}

get_system_env() {
    if is_ubuntu; then
        echo "Ubuntu"
    elif is_alpine; then
        echo "Alpine"
    else
        echo "Debian/Other"
    fi
}

cop_info(){
    clear
    local current_dns
    current_dns=$(get_current_dns)
    local lock_status
    lock_status=$(get_lock_status)
    local sys_env
    sys_env=$(get_system_env)

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}         ◈  DNS 自动化切换面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${sys_env}${RESET}"
    echo -e "${GREEN} 当前首选 DNS : ${YELLOW}${current_dns}${RESET}"
    echo -e "${GREEN} 配置文件状态 : ${lock_status}"
    echo -e "${GREEN}=======================================${RESET}"
}

# 返回菜单公共函数
back_to_menu() {
    echo
    read -rp "按回车键返回菜单..."
}

# 兼容 Alpine/Debian 的命令调用
run_chattr() {
    if command -v chattr &>/dev/null; then
        chattr "$@" 2>/dev/null || busybox chattr "$@" 2>/dev/null
    fi
}

########################################
# 修改 resolv.conf 文件模式（可锁定）
########################################
set_resolvconf_dns() {
    # 解锁
    if command -v lsattr &>/dev/null; then
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
            echo -e "${Info}检测到 resolv.conf 已锁定，正在解锁..."
            run_chattr -i /etc/resolv.conf
        fi
    fi

    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

    cat > /etc/resolv.conf <<EOF
nameserver $1
options timeout:2 attempts:3
EOF

    echo -e "${Info}DNS 已写入 resolv.conf"

    # 可选锁定
    echo -ne "${Tip}是否锁定 /etc/resolv.conf 防止被覆盖? (y/n): "
    read -r lock_choice
    if [[ "$lock_choice" == "y" || "$lock_choice" == "Y" ]]; then
        run_chattr +i /etc/resolv.conf
        echo -e "${Info}/etc/resolv.conf 已成功锁定！"
    fi
}

########################################
# 关闭 Ubuntu resolved 并写入 resolv.conf（可锁定）
########################################
disable_ubuntu_resolved() {
    echo -e "${Info}检测到 Ubuntu + systemd-resolved，正在关闭服务..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved

    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<EOF
nameserver $1
nameserver 1.1.1.1
options timeout:2 attempts:3
EOF

    echo -e "${Info}resolved 已关闭，DNS 已覆盖写入 /etc/resolv.conf"

    # 可选锁定
    echo -ne "${Tip}是否锁定 /etc/resolv.conf 防止被覆盖? (y/n): "
    read -r lock_choice
    if [[ "$lock_choice" == "y" || "$lock_choice" == "Y" ]]; then
        run_chattr +i /etc/resolv.conf
        echo -e "${Info}/etc/resolv.conf 已成功锁定！"
    fi
}

########################################
# 临时 resolvectl 模式
########################################
set_resolved_runtime_dns() {
    interface=$(ip route | awk '/default/ {print $5; exit}')
    if [ -z "$interface" ]; then
        echo -e "${Error}无法检测到默认网络接口"
        return
    fi
    resolvectl dns "$interface" "$1"
    resolvectl flush-caches
    echo -e "${Info}DNS 已通过 resolvectl 临时应用成功"
}

########################################
# 主循环
########################################
while true; do
    cop_info
    
    count=0
    for region in "${dns_order[@]}"; do
        ((count++))
        # 已改成一行显示一个
        printf "${GREEN}  %02d. %-12s${RESET}\n" "$count" "$region"
    done
    
    echo -e "${GREEN} ------------------------------------- ${RESET}"
    echo -e "${GREEN}   0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -ne "${GREEN} 请输入操作编号: ${RESET}"
    
    read -r choice

    # 支持 0 或 00 退出
    [[ "$choice" == "0" || "$choice" == "00" ]] && exit 0

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dns_order[@]} )); then
        region="${dns_order[$((choice-1))]}"

        if [ "$region" = "自定义" ]; then
            echo -ne "${Tip}请输入自定义 DNS IP: "
            read -r dns_to_set
            if [[ -z "$dns_to_set" ]]; then
                echo -e "${Error}未输入有效 IP，操作取消。"
                back_to_menu
                continue
            fi
        else
            dns_to_set="${dns_list[$region]}"
        fi

        echo -e "${Info}正在设置 DNS 为: ${YELLOW}$dns_to_set ($region)${NC} ..."

        # 核心判定分支
        if is_ubuntu && is_resolved_mode; then
            disable_ubuntu_resolved "$dns_to_set"
        elif is_resolved_mode; then
            set_resolved_runtime_dns "$dns_to_set"
        else
            set_resolvconf_dns "$dns_to_set"
        fi

        back_to_menu
    else
        echo -e "${Error}无效选择，请输入正确的数字编号。"
        sleep 1
    fi
done
