#!/bin/bash

# ========================================
# Croc 文件传输一键安装与使用脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 获取系统与Croc状态信息 (完美兼容 Alpine)
get_system_env() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        OS=$(uname -s)
    fi

    if command -v croc &>/dev/null; then
        CROC_STATUS="${GREEN}已安装 (${RESET}$(croc --version 2>/dev/null | awk '{print $3}')${GREEN})${RESET}"
    else
        CROC_STATUS="${RED}未安装${RESET}"
    fi
}

# 自动修复 Alpine 基础依赖并安装 Croc
install_croc() {
    echo -e "${YELLOW}➔ 正在检测并配置系统安装环境...${RESET}"
    
    # 针对 Alpine Linux 自动补齐基础依赖 (bash, coreutils, curl, tar)
    if [ -f /etc/alpine-release ]; then
        echo -e "${YELLOW}➔ 检测到 Alpine Linux，正在自动安装必备组件 (curl, tar, coreutils)...${RESET}"
        apk update && apk add curl tar coreutils >/dev/null 2>&1
    fi

    echo -e "${GREEN}➔ 开始获取官方最新版 Croc...${RESET}"
    if [[ "$OSTYPE" == "linux-gnu"* ]] || [ -f /etc/alpine-release ]; then
        # 使用更稳健的管道执行官方安装脚本
        curl -fsSL https://getcroc.schollz.com | bash
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install croc
        else
            echo -e "${RED}❌ 未检测到 Homebrew，请先安装 Homebrew 再重试。${RESET}"
            read -r -p "按回车返回..." ; return
        fi
    else
        echo -e "${RED}❌ 不支持的系统架构: $OSTYPE${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    # 验证安装状态
    if command -v croc &>/dev/null; then
        echo -e "${GREEN}🟢 Croc 核心传输组件安装成功！${RESET}"
    else
        echo -e "${RED}🔴 Croc 安装失败，请检查网络后重试。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 卸载 Croc
uninstall_croc() {
    echo -e "${YELLOW}➔ 正在卸载 Croc...${RESET}"
    if [[ "$OSTYPE" == "linux-gnu"* ]] || [ -f /etc/alpine-release ]; then
        if command -v croc &>/dev/null; then
            local croc_path
            croc_path=$(command -v croc)
            rm -f "$croc_path"
            echo -e "${GREEN}🟢 Croc 已从系统成功卸载。${RESET}"
        else
            echo -e "${YELLOW}⚠️  系统中未发现已安装的 Croc。${RESET}"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew uninstall croc 2>/dev/null
        echo -e "${GREEN}🟢 Croc 已从 macOS 卸载。${RESET}"
    else
        echo -e "${RED}❌ 不支持的系统架构: $OSTYPE${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 发送文件/目录（支持多路径）
send_file() {
    if ! command -v croc &>/dev/null; then
        echo -e "${RED}❌ 错误：请先选择选项 1 安装 Croc 核心传输组件。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    echo -e "${YELLOW}请输入要发送的文件或目录路径 (多个路径请用 空格 分隔):${RESET}"
    read -r -a paths
    
    # 检查输入是否为空
    if [ ${#paths[@]} -eq 0 ]; then
        echo -e "${YELLOW}操作已取消。${RESET}"
        read -r -p "按回车返回主菜单..." ; return
    fi

    # 检验路径合法性
    valid_paths=()
    for p in "${paths[@]}"; do
        if [[ -e "$p" ]]; then
            valid_paths+=("$p")
        else
            echo -e "${RED}❌ 路径不存在，已自动忽略: $p${RESET}"
        fi
    done

    if [[ ${#valid_paths[@]} -eq 0 ]]; then
        echo -e "${RED}🔴 没有找到任何有效路径，返回主菜单。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    echo -e "${GREEN}---------------------------------------${RESET}"
    read -r -p "请输入自定义接收代码 (直接回车则随机生成): " code
    echo -e "${GREEN}---------------------------------------${RESET}"

    if [[ -z "$code" ]]; then
        echo -e "${YELLOW}➔ 正在建立加密信道并自动生成代码...${RESET}"
        croc send "${valid_paths[@]}"
    else
        echo -e "${YELLOW}➔ 正在建立加密信道，使用自定义代码: ${YELLOW}$code${RESET}"
        croc send --code "$code" "${valid_paths[@]}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}🟢 文件/目录传输任务执行完毕。${RESET}"
    else
        echo -e "${RED}🔴 传输中断或发送失败。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 接收文件/目录
receive_file() {
    if ! command -v croc &>/dev/null; then
        echo -e "${RED}❌ 错误：请先选择选项 1 安装 Croc 核心传输组件。${RESET}"
        read -r -p "按回车返回..." ; return
    fi

    read -r -p "请输入接收连接代码 (Code): " code
    if [[ -z "$code" ]]; then
        echo -e "${RED}❌ 接收连接代码不能为空！${RESET}"
        read -r -p "按回车返回主菜单..." ; return
    fi

    echo -e "${YELLOW}➔ 正在连接远端传输中继...${RESET}"
    croc "$code"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}🟢 文件/目录安全接收完成！${RESET}"
    else
        echo -e "${RED}🔴 接收失败：连接超时、代码错误或信道断开。${RESET}"
    fi
    read -r -p "按回车返回主菜单..."
}

# 拟真科技面板主菜单循环
while true; do
    clear
    get_system_env
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}      ◈  Croc 点对点安全传输面板  ◈    ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 传输组件状态 : ${CROC_STATUS}${RESET}"
    echo -e "${GREEN} 加密传输协议 : ${YELLOW}PAKE (端到端全密文)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 安装/更新 Croc${RESET}"
    echo -e "${GREEN}  2) 卸载 Croc${RESET}"
    echo -e "${GREEN}  3) 安全发送本地文件/目录 (多选)${RESET}"
    echo -e "${GREEN}  4) 接收远端文件/目录 (凭码提取)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    echo -ne "${GREEN} 请选择操作编号: ${RESET}"
    read -r choice

    case $choice in
        1) install_croc ;;
        2) uninstall_croc ;;
        3) send_file ;;
        4) receive_file ;;
        0) echo -e "${YELLOW}正在退出系统...${RESET}" ; exit 0 ;;
        *) echo -e "${RED}❌ 无效选项，请输入正确的编号！${RESET}" ; read -r -p "按回车继续..." ;;
    esac
done
