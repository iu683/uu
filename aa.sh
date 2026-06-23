#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 自定义配置文件路径
ENV_FILE="$HOME/.codex_custom_env"

# 临时和永久确保当前脚本进程能找到最新的 PATH
export PATH="$HOME/.local/bin:$PATH"

# 自动刷新和导出自定义 API 环境配置（让主面板状态100%同步）
refresh_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        [ -n "$CODEX_BASE_URL" ] && export CODEX_BASE_URL="$CODEX_BASE_URL"
        [ -n "$OPENAI_BASE_URL" ] && export OPENAI_BASE_URL="$OPENAI_BASE_URL"
        [ -n "$OPENAI_API_KEY" ] && export OPENAI_API_KEY="$OPENAI_API_KEY"
        [ -n "$CODEX_API_KEY" ] && export CODEX_API_KEY="$CODEX_API_KEY"
        [ -n "$CODEX_MODEL" ] && export CODEX_MODEL="$CODEX_MODEL"
        [ -n "$CODEX_SUBAGENT_MODEL" ] && export CODEX_SUBAGENT_MODEL="$CODEX_SUBAGENT_MODEL"
    fi
}

# 首次和循环时加载环境
refresh_env

# 获取状态与版本信息
get_status() {
    if command -v codex &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(codex -v 2>/dev/null || codex --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="未知版本"
        codex_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        codex_version="${RED}-${RESET}"
    fi

    # 检查是否配置了自定义 API
    if [ -n "$CODEX_BASE_URL" ] || [ -n "$OPENAI_BASE_URL" ]; then
        api_status="${YELLOW}自定义中转${RESET}"
    else
        api_status="${GREEN}官方默认${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈    Codex CLI 管理面板   ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $codex_version"
    echo -e "${GREEN}API  :${RESET} $api_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 当前目录启动${RESET}"
    echo -e "${GREEN}3. 指定路径启动${RESET}"
    echo -e "${GREEN}4. 登录/切换账户${RESET}"
    echo -e "${GREEN}5. 设置自定义API模型/中转${RESET}"
    echo -e "${GREEN}6. 更新${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装
install_codex() {
    echo -e "\n${YELLOW}正在通过官方安装 Codex...${RESET}"
    curl -fsSL https://chatgpt.com/codex/install.sh | bash
    
    echo -e "\n${YELLOW}正在检查环境并自动修复 PATH...${RESET}"
    local shell_config=""
    if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
        shell_config="$HOME/.zshrc"
    else
        shell_config="$HOME/.bashrc"
    fi

    if ! grep -q '\.local/bin' "$shell_config" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_config"
        echo -e "${GREEN}✔ 已自动将 ~/.local/bin 写入 $shell_config${RESET}"
    else
        echo -e "${GREEN}✔ 配置文件中已存在 PATH 记录，无需重复添加。${RESET}"
    fi

    export PATH="$HOME/.local/bin:$PATH"
    echo -e "${GREEN}安装与修复完成！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current() {
    if command -v codex &> /dev/null; then
        echo -e "\n${GREEN}正在当前目录启动 Codex...${RESET}"
        refresh_env
        codex
    else
        echo -e "\n${RED}未检测到 codex 命令，请先执行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 3. 指定路径启动
start_path() {
    echo -e "\n"
    echo -ne "${GREEN}请输入你的项目绝对路径: ${RESET}"
    read target_path
    if [ -d "$target_path" ]; then
        echo -e "${GREEN}正在切换到 $target_path 并启动 Codex...${RESET}"
        refresh_env
        cd "$target_path" && codex
    else
        echo -e "${RED}路径不存在，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 登录
login_codex() {
    if command -v codex &> /dev/null; then
        echo -e "\n${YELLOW}正在启动登录程序...${RESET}"
        echo -e "提示：请按照屏幕指引选择使用你的 ChatGPT 账号登录"
        refresh_env
        codex login 2>/dev/null || codex
    else
        echo -e "\n${RED}未检测到已安装的 Codex。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 5. 配置高级自定义 API 模型路径和 Key
config_custom_api() {
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      自定义 API 配置管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前保存的 Base URL:${RESET} ${YELLOW}${CODEX_BASE_URL:-${OPENAI_BASE_URL:-官方默认}}${RESET}"
    echo -e "${GREEN}当前保存的主模型:${RESET}    ${YELLOW}${CODEX_MODEL:-默认 (gpt-4o)}${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}1. 快捷设置中转 / 代理模型配置${RESET}"
    echo -e "${GREEN}2. 清除自定义配置（恢复官方默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}1/4. 请输入自定义 API 中转地址/网关:${RESET}"
            echo -ne "   (例如: https://api.openai.com/v1 或你的AI代理地址)\n   地址: "
            read input_url
            
            echo -e "\n${YELLOW}2/4. 请输入你的 API Key / Token:${RESET}"
            echo -ne "   秘钥: "
            read input_key
            
            echo -e "\n${YELLOW}3/4. 请输入你想指定的主核心模型:${RESET}"
            echo -ne "   (直接回车默认使用: gpt-4o)\n   模型名: "
            read input_model
            [ -z "$input_model" ] && input_model="gpt-4o"

            echo -e "\n${YELLOW}4/4. 请输入你想指定的子代理 (Subagent) 模型:${RESET}"
            echo -ne "   (直接回车默认使用: gpt-4o-mini)\n   模型名: "
            read input_submodel
            [ -z "$input_submodel" ] && input_submodel="gpt-4o-mini"

            if [ -n "$input_url" ] && [ -n "$input_key" ]; then
                # 写入本地持久化环境配置文件，全量覆盖注入
                echo "export CODEX_BASE_URL=\"$input_url\"" > "$ENV_FILE"
                echo "export OPENAI_BASE_URL=\"$input_url\"" >> "$ENV_FILE"
                echo "export OPENAI_API_KEY=\"$input_key\"" >> "$ENV_FILE"
                echo "export CODEX_API_KEY=\"$input_key\"" >> "$ENV_FILE"
                echo "export CODEX_MODEL=\"$input_model\"" >> "$ENV_FILE"
                echo "export CODEX_SUBAGENT_MODEL=\"$input_submodel\"" >> "$ENV_FILE"
                
                # 触发即时生效
                refresh_env
                echo -e "\n${GREEN}✔ 恭喜！高级多模型变量已成功保存。启动时将全面生效。${RESET}"
            else
                echo -e "${RED}输入不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            if [ -f "$ENV_FILE" ]; then
                rm -f "$ENV_FILE"
                # 全量取消变量定义
                unset CODEX_BASE_URL OPENAI_BASE_URL OPENAI_API_KEY CODEX_API_KEY CODEX_MODEL CODEX_SUBAGENT_MODEL
                echo -e "${GREEN}✔ 已彻底清除自定义配置，成功恢复官方默认配置。${RESET}"
            else
                echo -e "${YELLOW}当前本来就是官方默认配置。${RESET}"
            fi
            ;;
        *)
            return
            ;;
    esac
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 更新
update_codex() {
    echo -e "\n${YELLOW}正在尝试更新 Codex...${RESET}"
    if command -v codex &> /dev/null; then
        codex update || curl -fsSL https://chatgpt.com/codex/install.sh | bash
    else
        echo -e "${RED}未检测到已安装的 Codex，无法更新。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 7. 整合卸载
uninstall_codex_flow() {
    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 Codex 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载程序
        echo -e "${YELLOW}[步骤 1/2] 正在删除主程序可执行文件...${RESET}"
        rm -f ~/.local/bin/codex
        rm -rf ~/.local/share/codex
        echo -e "${GREEN}✔ 主程序卸载成功。${RESET}"
        
        # 第二步：清除配置文件
        echo -e "\n${RED}[步骤 2/2] 是否需要连同配置文件、历史记录、自定义API设置一起清除？${RESET}"
        echo -e "${RED}注意：此操作不可逆，清除后所有本地历史将永久丢失！${RESET}"
        echo -ne "${RED}是否清除配置文件？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清除全局、本地及API配置文件...${RESET}"
            rm -rf ~/.codex
            rm -f ~/.codex.json
            rm -rf .codex
            rm -f "$ENV_FILE"
            echo -e "${GREEN}✔ 配置文件清除完毕，所有数据已彻底干净！${RESET}"
        else
            echo -e "${YELLOW}已保留配置文件。你可以随时重新安装并恢复使用。${RESET}"
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
        1) install_codex ;;
        2) start_current ;;
        3) start_path ;;
        4) login_codex ;;
        5) config_custom_api ;;
        6) update_codex ;;
        7) uninstall_codex_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
