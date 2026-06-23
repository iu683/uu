#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 获取状态与版本信息
get_status() {
    if command -v gemini &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(gemini --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        gemini_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        gemini_version="${RED}-${RESET}"
    fi

    # 检查当前配置的模型
    if command -v gemini &> /dev/null; then
        current_model=$(gemini config get model 2>/dev/null)
        [ -z "$current_model" ] && current_model="未设置"
        api_status="${GREEN}${current_model}${RESET}"
    else
        api_status="${RED}-${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Gemini CLI  管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $gemini_version"
    echo -e "${GREEN}模型 :${RESET} $api_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 配置API密钥${RESET}"
    echo -e "${GREEN}3. 调整模型与核心参数${RESET}"
    echo -e "${GREEN}4. 查看配置列表${RESET}"
    echo -e "${GREEN}5. 运行帮助命令${RESET}"
    echo -e "${GREEN}6. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装 (集成 Node.js v24 自动配置)
install_gemini() {
    echo -e "\n${YELLOW}[1/3] 正在检测 Node.js 环境...${RESET}"
    if ! command -v node &> /dev/null; then
        echo -e "${YELLOW}未检测到 Node.js，正在通过 NodeSource 配置 Node.js v24 源...${RESET}"
        
        # 确保系统有 curl
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}检测到缺少 curl，正在尝试安装...${RESET}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y curl
            elif command -v dnf &> /dev/null; then
                dnf install -y curl
            elif command -v yum &> /dev/null; then
                yum install -y curl
            fi
        fi

        # 执行 NodeSource v24 脚本
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        
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
            echo -e "${RED}❌ 未能识别系统包管理器，请手动运行：apt/dnf install -y nodejs${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
            return
        fi
    fi
    
    # 再次确认 Node 版本
    if command -v node &> /dev/null; then
        echo -e "${GREEN}✔ Node.js 已就绪，版本: $(node --version)${RESET}"
        echo -e "${GREEN}✔ npm 版本: $(npm --version)${RESET}"
    else
        echo -e "${RED}❌ Node.js 安装失败，请检查网络或系统权限。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${YELLOW}[2/3] 正在通过 npm 全局安装 @google/gemini-cli...${RESET}"
    npm install -g @google/gemini-cli

    echo -e "\n${YELLOW}[3/3] 验证安装状态...${RESET}"
    if command -v gemini &> /dev/null; then
        echo -e "\n${GREEN}✔ Gemini CLI 成功部署并激活！${RESET}"
        echo -e "${YELLOW}$(gemini --version)${RESET}"
    else
        echo -e "\n${RED}❌ Gemini CLI 全局安装成功但命令未找到，可能需要将 npm 全局 bin 目录加入到 PATH 中。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 配置 API 密钥
config_api_key() {
    if ! command -v gemini &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 Gemini CLI！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${YELLOW}请输入你的 Gemini API 密钥 (API Key):${RESET}"
    echo -ne " Key: "
    read input_key

    if [ -n "$input_key" ]; then
        gemini config set api-key "$input_key"
        echo -e "\n${GREEN}✔ API 密钥配置成功！验证结果如下：${RESET}"
        echo -ne "当前生效 Key: "
        gemini config get api-key
    else
        echo -e "${RED}输入不能为空，取消设置。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 3. 调整参数
config_params() {
    if ! command -v gemini &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 Gemini CLI！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}       Gemini 参数快速调整       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    # 1. 模型设置
    echo -e "${YELLOW}1/3. 请输入默认模型名称 (直接回车默认: gemini-pro):${RESET}"
    echo -ne " 模型名: "
    read input_model
    [ -z "$input_model" ] && input_model="gemini-pro"
    gemini config set model "$input_model"

    # 2. 创造性设置
    echo -e "\n${YELLOW}2/3. 请输入创造性参数 temperature (0.0 ~ 2.0，直接回车默认: 0.7):${RESET}"
    echo -ne " Temperature: "
    read input_temp
    [ -z "$input_temp" ] && input_temp="0.7"
    gemini config set temperature "$input_temp"

    # 3. 最大长度设置
    echo -e "\n${YELLOW}3/3. 请输入最大输出长度 maxTokens (直接回车默认: 2000):${RESET}"
    echo -ne " MaxTokens: "
    read input_tokens
    [ -z "$input_tokens" ] && input_tokens="2000"
    gemini config set maxTokens "$input_tokens"

    echo -e "\n${GREEN}✔ 参数修改成功！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 4. 查看配置列表
view_config() {
    if ! command -v gemini &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 Gemini CLI！${RESET}"
    else
        echo -e "\n${YELLOW}--- 当前 Gemini CLI 完整配置列表 ---${RESET}"
        gemini config list
        echo -e "${YELLOW}-----------------------------------${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 5. 帮助命令
show_help() {
    if ! command -v gemini &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装 Gemini CLI！${RESET}"
    else
        echo -e "\n${YELLOW}--- gemini --help 输出 ---${RESET}"
        gemini --help
        echo -e "${YELLOW}--------------------------${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 整合卸载（包含配置与环境清理）
uninstall_gemini_flow() {
    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 Gemini CLI 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载 CLI 主程序
        echo -e "${YELLOW}[步骤 1/3] 正在通过 npm 卸载全局 @google/gemini-cli...${RESET}"
        npm uninstall -g @google/gemini-cli
        echo -e "${GREEN}✔ 主程序卸载指令执行完毕。${RESET}"
        
        # 第二步：清除本地配置
        echo -e "\n${RED}[步骤 2/3] 是否需要连同 Gemini CLI 的本地配置文件与历史缓存一起清除？${RESET}"
        echo -e "${RED}注意：通常包含全局密钥和自定义的模型配置。${RESET}"
        echo -ne "${RED}是否清除配置文件？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清理本地存储目录 ~/.gemini 及相关隐藏配置文件...${RESET}"
            rm -rf "$HOME/.gemini"
            rm -rf "$HOME/.config/gemini" 2>/dev/null
            echo -e "${GREEN}✔ 配置文件与本地缓存已彻底清除。${RESET}"
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
        1) install_gemini ;;
        2) config_api_key ;;
        3) config_params ;;
        4) view_config ;;
        5) show_help ;;
        6) uninstall_gemini_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
