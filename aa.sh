#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 自定义配置文件路径
ENV_FILE="$HOME/.claude_custom_env"

# 临时和永久确保当前脚本进程能找到最新的 PATH
export PATH="$HOME/.local/bin:$PATH"

# 自动刷新和导出自定义 API 环境配置（让主面板状态100%同步）
refresh_env() {
    # 先清理当前进程中的历史干扰变量
    unset CLAUDE_BASE_URL ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL

    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

# 首次和循环时加载环境
refresh_env

# 获取状态与版本信息
get_status() {
    if command -v claude &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(claude -v 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="未知版本"
        claude_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        claude_version="${RED}-${RESET}"
    fi

    # 检查是否配置了自定义 API
    if [ -f "$ENV_FILE" ] && ( [ -n "$CLAUDE_BASE_URL" ] || [ -n "$ANTHROPIC_BASE_URL" ] ); then
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
    echo -e "${GREEN}    ◈  Claude Code 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $claude_version"
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
install_claude() {
    echo -e "\n${YELLOW}正在通过官方安装 Claude Code...${RESET}"
    curl -fsSL https://claude.ai/install.sh | bash
    
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
    if command -v claude &> /dev/null; then
        echo -e "\n${GREEN}正在当前目录启动 Claude Code...${RESET}"
        refresh_env
        claude
    else
        echo -e "\n${RED}未检测到 claude 命令，请先执行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 3. 指定路径启动
start_path() {
    echo -e "\n"
    echo -ne "${GREEN}请输入你的项目绝对路径: ${RESET}"
    read target_path
    if [ -d "$target_path" ]; then
        echo -e "${GREEN}正在切换到 $target_path 并启动 Claude Code...${RESET}"
        refresh_env
        cd "$target_path" && claude
    else
        echo -e "${RED}路径不存在，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 登录
login_claude() {
    if command -v claude &> /dev/null; then
        echo -e "\n${YELLOW}正在启动登录程序...${RESET}"
        echo -e "提示：如果已经在会话中，直接输入 /login 即可"
        refresh_env
        claude -c "/login" 2>/dev/null || claude
    else
        echo -e "\n${RED}未检测到已安装的 Claude Code。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 5. 配置高级自定义 API 模型路径和 Key
config_custom_api() {
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      自定义 API 配置管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前保存的 Base URL:${RESET} ${YELLOW}${CLAUDE_BASE_URL:-${ANTHROPIC_BASE_URL:-官方默认}}${RESET}"
    echo -e "${GREEN}当前保存的主模型:${RESET}    ${YELLOW}${ANTHROPIC_MODEL:-默认 (Sonnet/Opus)}${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}1. 快捷设置 DeepSeek / 代理模型配置${RESET}"
    echo -e "${GREEN}2. 清除自定义配置（恢复官方默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}1/4. 请输入自定义 API 中转地址/网关:${RESET}"
            echo -ne "   (提示: 中转通常需带 /v1，例如: https://www.soyenai.com/v1)\n   地址: "
            read input_url
            
            echo -e "\n${YELLOW}2/4. 请输入你的 API Key / Token:${RESET}"
            echo -ne "   秘钥: "
            read input_key
            
            echo -e "\n${YELLOW}3/4. 请输入你想指定的主核心模型:${RESET}"
            echo -ne "   (直接回车默认使用: deepseek-v4-pro)\n   模型名: "
            read input_model
            [ -z "$input_model" ] && input_model="deepseek-v4-pro"

            echo -e "\n${YELLOW}4/4. 请输入你想指定的子代理 (Subagent) 模型:${RESET}"
            echo -ne "   (直接回车默认使用: deepseek-v4-flash)\n   模型名: "
            read input_submodel
            [ -z "$input_submodel" ] && input_submodel="deepseek-v4-flash"

            if [ -n "$input_url" ] && [ -n "$input_key" ]; then
                # 写入本地持久化环境配置文件，全量覆盖注入
                echo "# Claude Code 自定义代理持久化环境" > "$ENV_FILE"
                echo "export CLAUDE_BASE_URL=\"$input_url\"" >> "$ENV_FILE"
                echo "export ANTHROPIC_BASE_URL=\"$input_url\"" >> "$ENV_FILE"
                
                # 【防冲突核心】只使用 AUTH_TOKEN 并强行清除 API_KEY 规避官方客户端报错
                echo "export ANTHROPIC_AUTH_TOKEN=\"$input_key\"" >> "$ENV_FILE"
                echo "unset ANTHROPIC_API_KEY" >> "$ENV_FILE"
                
                # 模型映射劫持
                echo "export ANTHROPIC_MODEL=\"$input_model\"" >> "$ENV_FILE"
                echo "export ANTHROPIC_DEFAULT_OPUS_MODEL=\"$input_model\"" >> "$ENV_FILE"
                echo "export ANTHROPIC_DEFAULT_SONNET_MODEL=\"$input_model\"" >> "$ENV_FILE"
                
                # 子代理（Subagent）配置
                echo "export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"$input_submodel\"" >> "$ENV_FILE"
                echo "export CLAUDE_CODE_SUBAGENT_MODEL=\"$input_submodel\"" >> "$ENV_FILE"
                echo "export CLAUDE_CODE_EFFORT_LEVEL=\"max\"" >> "$ENV_FILE"
                
                # 【避坑检查】如果存在全局 settings.json，它的 env 会覆盖这里的 export，故进行改名备份
                if [ -f "$HOME/.claude/settings.json" ]; then
                    mv "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak" 2>/dev/null
                    echo -e "${YELLOW}⚠ 检测到已存在的 settings.json 可能引发配置冲突，已自动将其备份为 settings.json.bak${RESET}"
                fi

                # 触发即时生效并刷新
                refresh_env
                echo -e "\n${GREEN}✔ 恭喜！高级多模型变量已成功保存。启动时将全面劫持并生效。${RESET}"
            else
                echo -e "${RED}输入不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            if [ -f "$ENV_FILE" ] || [ -f "$HOME/.claude/settings.json.bak" ]; then
                rm -f "$ENV_FILE"
                # 尝试恢复原有的 settings.json
                if [ -f "$HOME/.claude/settings.json.bak" ]; then
                    mv "$HOME/.claude/settings.json.bak" "$HOME/.claude/settings.json" 2>/dev/null
                fi
                # 全量取消变量定义
                refresh_env
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
update_claude() {
    echo -e "\n${YELLOW}正在尝试更新 Claude Code...${RESET}"
    if command -v claude &> /dev/null; then
        claude update || claude install
    else
        echo -e "${RED}未检测到已安装的 Claude Code，无法更新。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 7. 整合卸载
uninstall_claude_flow() {
    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 Claude Code 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载程序
        echo -e "${YELLOW}[步骤 1/2] 正在删除主程序可执行文件...${RESET}"
        rm -f ~/.local/bin/claude
        rm -rf ~/.local/share/claude
        echo -e "${GREEN}✔ 主程序卸载成功。${RESET}"
        
        # 第二步：清除配置文件
        echo -e "\n${RED}[步骤 2/2] 是否需要连同配置文件、历史记录、自定义API及MCP设置一起清除？${RESET}"
        echo -e "${RED}注意：此操作不可逆，清除后所有本地历史将永久丢失！${RESET}"
        echo -ne "${RED}是否清除配置文件？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清除全局、本地及API配置文件...${RESET}"
            rm -rf ~/.claude
            rm -f ~/.claude.json
            rm -rf .claude
            rm -f .mcp.json
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
        1) install_claude ;;
        2) start_current ;;
        3) start_path ;;
        4) login_claude ;;
        5) config_custom_api ;;
        6) update_claude ;;
        7) uninstall_claude_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
