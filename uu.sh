#!/bin/bash
# ========================================
# DeepSeek-TUI 一键管理脚本
# ========================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 检查 root 权限 (用于安装/卸载等核心步骤)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}❌ 错误: 此操作需要 root 权限，请使用 sudo 运行本脚本或切换到 root 用户！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return 1
    fi
    return 0
}

# 获取状态与版本信息
get_status() {
    if command -v deepseek &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        # 获取版本号，通常深层 cli 的命令是 deepseek --version
        version_info=$(deepseek --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        deepseek_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        deepseek_version="${RED}-${RESET}"
    fi

    # 检查当前配置的模型/服务商 (通过内置的 doctor 或者是查配置目录隐式判断)
    if command -v deepseek &> /dev/null; then
        # 尝试读取可能存在的服务商配置状态
        if [ -d "$HOME/.deepseek" ] || [ -d "/root/.deepseek" ]; then
            api_status="${GREEN}已配置/DeepSeek${RESET}"
        else
            api_status="${YELLOW}未初始化${RESET}"
        fi
    else
        api_status="${RED}-${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈  DeepSeek-TUI  管理面板  ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $deepseek_version"
    echo -e "${GREEN}配置 :${RESET} $api_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 配置API密钥${RESET}"
    echo -e "${GREEN}3. 运行环境检查${RESET}"
    echo -e "${GREEN}4. 启动 DeepSeekTUI${RESET}"
    echo -e "${GREEN}5. 更新${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装 (集成 Node.js 自动配置)
install_app() {
    check_root || return

    echo -e "\n${YELLOW}[1/3] 正在检测 Node.js 环境...${RESET}"
    if ! command -v node &> /dev/null; then
        echo -e "${YELLOW}未检测到 Node.js，正在尝试自动配置 Node.js LTS 源...${RESET}"
        
        # 确保系统有 curl
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}检测到缺少 curl，正在尝试安装...${RESET}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y curl ca-certificates gnupg
            elif command -v dnf &> /dev/null; then
                dnf install -y curl
            elif command -v yum &> /dev/null; then
                yum install -y epel-release && yum install -y curl
            fi
        fi

        # 执行 NodeSource LTS 脚本
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        
        # 根据包管理器执行安装
        if command -v apt-get &> /dev/null; then
            echo -e "${YELLOW}正在通过 apt 安装 nodejs...${RESET}"
            apt-get install -y nodejs
        elif command -v dnf &> /dev/null; then
            echo -e "${YELLOW}正在通过 dnf 安装 nodejs...${RESET}"
            dnf install -y nodejs
        elif command -v yum &> /dev/null; then
            echo -e "${YELLOW}正在通过 yum 安装 nodejs...${RESET}"
            yum install -y nodejs
        else
            echo -e "${RED}❌ 未能识别系统包管理器，请手动安装 Node.js 后再试。${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
            return
        fi
    fi
    
    # 验证 Node 版本
    if command -v node &> /dev/null; then
        echo -e "${GREEN}✔ Node.js 已就绪，版本: $(node --version)${RESET}"
        echo -e "${GREEN}✔ npm 版本: $(npm --version)${RESET}"
    else
        echo -e "${RED}❌ Node.js 安装失败，请检查网络或系统源设置。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${YELLOW}[2/3] 正在通过 npm 全局安装 deepseek-tui...${RESET}"
    npm install -g deepseek-tui

    echo -e "\n${YELLOW}[3/3] 验证安装状态...${RESET}"
    if command -v deepseek &> /dev/null; then
        echo -e "\n${GREEN}✔ DeepSeek-TUI 成功部署并激活！${RESET}"
        echo -e "${YELLOW}当前版本: $(deepseek --version 2>/dev/null)${RESET}"
    else
        echo -e "\n${RED}❌ 安装可能成功，但未找到 deepseek 命令，请确保 npm 的全局 bin 目录在系统 PATH 中。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 配置 API 供应商
set_auth() {
    if ! command -v deepseek &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 DeepSeek-TUI！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${YELLOW}即将调用交互式配置服务商命令行...${RESET}"
    echo -e "${YELLOW}提示：请根据终端提示选择服务商（如 deepseek）并填入 API Key。${RESET}\n"
    
    deepseek auth set --provider deepseek

    echo -ne "\n${GREEN}配置流引导完成。按回车键返回主菜单...${RESET}" && read
}

# 3. Doctor 环境检查
doctor_app() {
    if ! command -v deepseek &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 DeepSeek-TUI！${RESET}"
    else
        echo -e "\n${YELLOW}--- DeepSeek Doctor 诊断输出 ---${RESET}"
        deepseek doctor
        echo -e "${YELLOW}--------------------------------${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 4. 启动客户端
start_app() {
    if ! command -v deepseek &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 DeepSeek-TUI！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi
    echo -e "\n${GREEN}正在为您唤醒 DeepSeek-TUI 终端界面...${RESET}\n"
    deepseek
}

# 5. 更新应用
update_app() {
    check_root || return

    if ! command -v deepseek &> /dev/null; then
        echo -e "\n${YELLOW}未检测到已安装的 DeepSeek-TUI，将直接进入安装流程...${RESET}"
        install_app
        return
    fi

    echo -e "\n${YELLOW}正在通过 npm 将 deepseek-tui 升级至最新版本...${RESET}"
    npm install -g deepseek-tui@latest

    echo -e "\n${GREEN}✔ 更新指令执行完毕！当前版本信息：${RESET}"
    echo -e "${YELLOW}$(deepseek --version 2>/dev/null)${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 整合卸载（包含配置与环境清理）
uninstall_app_flow() {
    check_root || return

    if ! command -v deepseek &> /dev/null; then
        echo -e "\n${YELLOW}系统未安装 DeepSeek-TUI，无需卸载。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 DeepSeek-TUI 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载主程序
        echo -e "${YELLOW}[步骤 1/2] 正在通过 npm 卸载全局 deepseek-tui...${RESET}"
        npm uninstall -g deepseek-tui
        echo -e "${GREEN}✔ 主程序卸载完毕。${RESET}"
        
        # 第二步：清除本地配置
        echo -e "\n${RED}[步骤 2/2] 是否需要连同本地的配置文件（如保存的 API Key 及历史缓存）一起清除？${RESET}"
        echo -ne "${RED}是否清除本地缓存及配置目录？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清理本地存储目录 ~/.deepseek 及相关缓存...${RESET}"
            rm -rf "$HOME/.deepseek"
            rm -rf "/root/.deepseek" 2>/dev/null
            echo -e "${GREEN}✔ 配置文件与本地缓存已彻底清理。${RESET}"
        else
            echo -e "${YELLOW}已保留本地配置文件。${RESET}"
        fi
    else
        echo "已取消卸载操作。"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 主循环
while true; do
    show_menu
    read choice
    case $choice in
        1) install_app ;;
        2) set_auth ;;
        3) doctor_app ;;
        4) start_app ;;
        5) update_app ;;
        6) uninstall_app_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
