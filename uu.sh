#!/bin/bash
# ========================================
# Windows 10 DD 安装脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 代理前缀
PROXY="https://v6.gh-proxy.org/"

# GitHub 脚本资源地址
LEITBOGIORO_URL="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
BIN456789_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

# 检测是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户或 sudo 运行此脚本${RESET}"
    exit 1
fi

# 安装必要工具
install_tools() {
    echo -e "${GREEN}正在更新系统并安装必要工具...${RESET}"
    apt update
    apt install -y curl wget || { echo -e "${RED}工具安装失败，请检查网络${RESET}"; exit 1; }
}

# 显示默认账户信息
show_account_info() {
    echo -e "${YELLOW}默认账户信息:${RESET}"
    echo -e "${YELLOW}用户名: Administrator${RESET}"
    echo -e "${YELLOW}密码: Teddysun.com${RESET}"
    echo -e "${GREEN}提示:${RESET}"
    echo -e "${YELLOW}在 Windows 中可以使用快捷键 Windows + R 打开“运行”框，输入 powershell 回车，进入 PowerShell 窗口。${RESET}"
    echo -e "${YELLOW}输入以下命令：irm https://get.activated.win | iex 激活 ${RESET}"
    echo -e "${GREEN}请在合适的时候手动输入'reboot'重启系统${RESET}"
}

# 重启提示
prompt_reboot() {
    # 变更为绿色 read 提示
    read -p $'\033[32m是否立即重启系统？(y/N): \033[0m' answer
    case $answer in
        [Yy]*) echo -e "${GREEN}系统即将重启...${RESET}"; reboot ;;
        *) echo -e "${GREEN}已取消，请稍后手动重启${RESET}" ;;
    esac
}

# V4DD 安装流程
install_v4dd() {
    echo -e "${GREEN}开始 V4DD Windows 10 安装流程...${RESET}"
    
    # 检查下载工具
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || install_tools

    # 优先直连，失败自动切代理
    bash <(curl -fsSL "$LEITBOGIORO_URL") -windows 10 -lang "cn" || \
    bash <(curl -fsSL "${PROXY}${LEITBOGIORO_URL}") -windows 10 -lang "cn" || {
        echo -e "${RED}错误：直连与代理均无法下载核心脚本，请检查网络设置。${RESET}"
        return
    }
    
    show_account_info
    prompt_reboot
}

# V6DD 安装流程
install_v6dd() {
    echo -e "${GREEN}开始 V6DD Windows 10 安装流程...${RESET}"

    # 检查下载工具
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || install_tools
    
    # 优先直连下载，失败切代理下载
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o reinstall.sh "$BIN456789_URL" || \
        curl -fsSL -o reinstall.sh "${PROXY}${BIN456789_URL}" || { echo -e "${RED}下载失败${RESET}"; return; }
    else
        wget -q "$BIN456789_URL" -O reinstall.sh || \
        wget -q "${PROXY}${BIN456789_URL}" -O reinstall.sh || { echo -e "${RED}下载失败${RESET}"; return; }
    fi

    # 确保下载到的文件有效
    if [ ! -s reinstall.sh ]; then
        echo -e "${RED}错误：未能成功下载有效的 reinstall.sh 文件${RESET}"
        return
    fi

    chmod +x reinstall.sh

    # 使用官方镜像 URL 执行 DD
    bash reinstall.sh dd --img https://dl.lamp.sh/vhd/zh-cn_windows10_ltsc.xz

    show_account_info
    prompt_reboot
}

# 菜单主循环
while true; do
    clear
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}           Windows10 DD            ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1) V4 DD 安装Windows10${RESET}"
    echo -e "${GREEN}2) V6 DD 安装Windows10${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    
    read -p $'\033[32m请输入编号: \033[0m' choice
    case $choice in
        1) install_v4dd ;;
        2) install_v6dd ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
    esac
    echo -e "${GREEN}按回车返回菜单...${RESET}"
    read
done
