#!/bin/bash
# ========================================
# Croc 文件传输一键安装与使用脚本（支持多文件/多目录）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 检查系统命令
check_command() {
    command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}请先安装 $1${RESET}"; exit 1; }
}

# 安装 Croc
install_croc() {
    echo -e "${GREEN}正在安装 Croc...${RESET}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -s https://getcroc.schollz.com | bash
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew install croc
    else
        echo -e "${RED}不支持的系统: $OSTYPE${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Croc 安装完成!${RESET}"
    read -r -p "按回车返回主菜单..."
}

# 卸载 Croc
uninstall_croc() {
    echo -e "${YELLOW}正在卸载 Croc...${RESET}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v croc >/dev/null 2>&1; then
            rm -f "$(command -v croc)"
            echo -e "${GREEN}Croc 已卸载${RESET}"
        else
            echo -e "${RED}Croc 未安装${RESET}"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew uninstall croc
        echo -e "${GREEN}Croc 已卸载${RESET}"
    else
        echo -e "${RED}不支持的系统: $OSTYPE${RESET}"
        exit 1
    fi
    read -r -p "按回车返回主菜单..."
}

# 发送文件/目录（支持多路径）
send_file() {
    echo -e "${YELLOW}请输入要发送的文件或目录路径，多个路径用空格分隔:${RESET}"
    read -r -a paths
    # 检查路径是否存在
    valid_paths=()
    for p in "${paths[@]}"; do
        if [[ -e "$p" ]]; then
            valid_paths+=("$p")
        else
            echo -e "${RED}路径不存在: $p${RESET}"
        fi
    done
    if [[ ${#valid_paths[@]} -eq 0 ]]; then
        echo -e "${RED}没有有效路径，返回主菜单${RESET}"
        read -r -p "按回车返回主菜单..."
        return
    fi
    read -r -p "请输入接收代码（自定义或留空随机生成）: " code
    if [[ -z "$code" ]]; then
        echo -e "${GREEN}开始发送，自动生成 code...${RESET}"
        croc send "${valid_paths[@]}"
    else
        echo -e "${GREEN}开始发送，使用 code: $code${RESET}"
        croc send --code "$code" "${valid_paths[@]}"
    fi
    echo -e "${GREEN}发送完成！${RESET}"
    read -r -p "按回车返回主菜单..."
}

# 接收文件/目录
receive_file() {
    read -r -p "请输入接收代码: " code
    if [[ -z "$code" ]]; then
        echo -e "${RED}接收代码不能为空${RESET}"
        read -r -p "按回车返回主菜单..."
        return
    fi
    echo -e "${GREEN}开始接收文件...${RESET}"
    croc "$code"
    echo -e "${GREEN}接收完成！${RESET}"
    read -r -p "按回车返回主菜单..."
}

# 主菜单
while true; do
    clear
    echo -e "${GREEN}=== Croc 文件传输 ===${RESET}"
    echo -e "${GREEN}1. 安装 Croc${RESET}"
    echo -e "${GREEN}2. 卸载 Croc${RESET}"
    echo -e "${GREEN}3. 发送文件/目录（支持多路径）${RESET}"
    echo -e "${GREEN}4. 接收文件/目录${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -r -p $'\033[32m请选择操作: \033[0m' choice

    case $choice in
        1) install_croc ;;
        2) uninstall_croc ;;
        3) check_command croc; send_file ;;
        4) check_command croc; receive_file ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; read -r -p "按回车返回主菜单..." ;;
    esac
done
