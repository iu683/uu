#!/bin/bash

# ----------------------
# 定义颜色
# ----------------------
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ----------------------
# 通用安装函数
# ----------------------
install_tool() {
    local pkg="$1"
    echo -e "${GREEN}正在安装 $pkg ...${RESET}"
    if command -v apt &>/dev/null; then
        apt update && apt install -y "$pkg"
    elif command -v yum &>/dev/null; then
        yum install -y "$pkg"
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$pkg"
    else
        echo -e "${RED}不支持的包管理器${RESET}"
        return 1
    fi
    echo -e "${GREEN}$pkg 安装完成${RESET}"
}

# ----------------------
# 系统检测函数
# ----------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        os_name=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    elif command -v lsb_release &>/dev/null; then
        os_name=$(lsb_release -i | cut -f2 | tr -d '"')
    else
        echo -e "${RED}无法确定操作系统类型${RESET}"
        exit 1
    fi
}

# ----------------------
# 系统安装函数
# ----------------------
install_sys_tool() {
    local tool="$1"
    echo -e "${GREEN}正在安装 $tool ...${RESET}"

    case "$os_name" in
        centos|rocky)
            yum install epel-release -y
            yum install -y "$tool"
            ;;

        amzn)
            amazon-linux-extras install epel -y
            yum install -y "$tool"
            ;;

        debian|ubuntu)
            if [[ "$tool" == "mtr" ]]; then
                apt update && apt install -y mtr-tiny
            else
                apt update && apt install -y "$tool"
            fi
            ;;

        alpine)
            apk add --no-cache "$tool"
            ;;

        *)
            install_tool "$tool"
            ;;
    esac

    echo -e "${GREEN}$tool 安装完成${RESET}"
}


# ----------------------
# 在 / 目录运行工具
# ----------------------
run_in_root() {
    cd / || return
    "$@"
    cd ~ || return
}

# ----------------------
# 显示帮助或运行工具
# ----------------------
run_tool() {
    local tool="$1"
    local mode="$2" # help / run
    case "$mode" in
        help)
            echo -e "${GREEN}显示 $tool 帮助信息:${RESET}"
            "$tool" --help
            ;;
        run)
            echo -e "${GREEN}运行 $tool ...${RESET}"
            "$tool"
            ;;
        *)
            echo -e "${RED}未知模式: $mode${RESET}"
            ;;
    esac
}

# ----------------------
# 判断工具是否已安装，返回状态
# ----------------------
check_installed() {
    local tool="$1"
    if command -v "$tool" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ----------------------
# 工具列表及支持系统
# ----------------------
declare -A tools
tools=(
    [1]="curl:help:"
    [2]="wget:help:"
    [3]="sudo:help:"
    [4]="socat:help:"
    [5]="htop:run:"
    [6]="iftop:run:"
    [7]="unzip:help:"
    [8]="tar:help:"
    [9]="tmux:help:"
    [10]="ffmpeg:help:"
    [11]="btop:run:"
    [12]="ranger:run_root:"
    [13]="ncdu:run_root:"
    [14]="fzf:run_root:"
    [15]="vim:help_root:"
    [16]="nano:help_root:"
    [17]="git:help_root:"
    [18]="screen:sys:centos,rocky,amzn"
    [19]="masscan:sys:centos,rocky,amzn"
    [20]="iperf3:sys:"
    [21]="mtr:sys:"
)

# ----------------------
# 显示菜单函数（菜单字体绿色，状态彩色）
# ----------------------
show_menu() {
    clear
    echo -e "${GREEN}========== 工具安装菜单 ===========${RESET}"
    echo -e "${GREEN}系统: $os_name${RESET}"
    for i in $(seq 1 21); do
        IFS=":" read -r tool mode support_os <<< "${tools[$i]}"
        if [[ -n "$support_os" && ! ",$support_os," =~ ",$os_name," ]]; then
            continue
        fi
        if check_installed "$tool"; then
            status="${GREEN}✔ 已安装${RESET}"
        else
            status="${RED}✖ 未安装${RESET}"
        fi

        if [[ $i -lt 10 ]]; then
            # 小于 10 → 前补零
            printf "${GREEN} [0%d] %-10s${RESET} %b\n" "$i" "$tool" "$status"
        else
            printf "${GREEN} [%2d] %-10s${RESET} %b\n" "$i" "$tool" "$status"
        fi
    done
    echo -e "${GREEN} [99] 卸载已安装工具${RESET}"
    echo -e "${GREEN} [00] 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
}


# ----------------------
# 卸载函数（支持多选）
# ----------------------
uninstall_tool() {
    installed_tools=()
    for i in $(seq 1 21); do
        IFS=":" read -r tool mode support_os <<< "${tools[$i]}"
        if check_installed "$tool"; then
            installed_tools+=("$tool")
        fi
    done

    if [ ${#installed_tools[@]} -eq 0 ]; then
        echo -e "${RED}没有已安装的工具可卸载${RESET}"
        return
    fi

    echo -e "${YELLOW}已安装工具:${RESET}"
    for idx in "${!installed_tools[@]}"; do
        echo -e "${GREEN}$((idx+1))) ${installed_tools[$idx]}${RESET}"
    done

    read -rp $'\033[32m请输入要卸载的编号（空格或逗号分隔可多选）: \033[0m' choices
    # 替换逗号为空格
    choices=${choices//,/ }
    for choice in $choices; do
        if [[ "$choice" -ge 1 && "$choice" -le ${#installed_tools[@]} ]]; then
            tool_to_remove="${installed_tools[$((choice-1))]}"
            echo -e "${GREEN}正在卸载 $tool_to_remove ...${RESET}"
            if command -v apt &>/dev/null; then
                apt remove -y "$tool_to_remove"
            elif command -v yum &>/dev/null; then
                yum remove -y "$tool_to_remove"
            elif command -v apk &>/dev/null; then
                apk del "$tool_to_remove"
            else
                echo -e "${RED}不支持的包管理器${RESET}"
            fi
            echo -e "${GREEN}$tool_to_remove 卸载完成${RESET}"
        else
            echo -e "${RED}无效选择: $choice${RESET}"
        fi
    done
}

# ----------------------
# 主程序
# ----------------------
detect_os

while true; do
    show_menu
    read -rp $'\033[32m请输入要操作的编号: \033[0m' sub_choice

    # 验证输入是否为纯数字
    if ! [[ "$sub_choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效输入，请输入数字${RESET}"
        read -rp "按回车返回菜单..." _
        continue
    fi

    [[ "$sub_choice" == "0" || "$sub_choice" == "00" ]] && break

    if [[ "$sub_choice" == "99" ]]; then
        uninstall_tool
        echo -e "${GREEN}按回车返回菜单...${RESET}"
        read -r
        continue
    fi

    if [[ -n "${tools[$sub_choice]}" ]]; then
        IFS=":" read -r tool mode support_os <<< "${tools[$sub_choice]}"
        clear
        case "$mode" in
            help) install_tool "$tool" && run_tool "$tool" help ;;
            run) install_tool "$tool" && run_tool "$tool" run ;;
            run_root) install_tool "$tool" && run_in_root "$tool" ;;
            help_root) install_tool "$tool" && run_in_root "$tool" -h ;;
            sys) install_sys_tool "$tool" ;;
            *) echo -e "${RED}未知模式: $mode${RESET}" ;;
        esac
        cd ~
        echo -e "${GREEN}按回车返回菜单...${RESET}"
        read -r
    else
        echo -e "${RED}无效选择: $sub_choice${RESET}"
        echo -e "${GREEN}按回车返回菜单...${RESET}"
        read -r
    fi
done
