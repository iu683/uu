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

# 自动刷新和导出自定义 API 环境配置
refresh_env() {
    # 优先从本地 settings.json 中解析当前状态，保证主面板状态 100% 同步
    local SETTINGS_JSON="$HOME/.claude/settings.json"
    if [ -f "$SETTINGS_JSON" ]; then
        # 简单通过 grep 判定是否配置了自定义中转（免去安装 jq 的依赖）
        if grep -q '"ANTHROPIC_BASE_URL"' "$SETTINGS_JSON" 2>/dev/null; then
            IS_CUSTOM_API=true
            # 从 JSON 中提取当前的 Base URL 和 Model（用于主面板展示）
            CURRENT_URL=$(grep '"ANTHROPIC_BASE_URL"' "$SETTINGS_JSON" | sed -E 's/.*"ANTHROPIC_BASE_URL": ?"([^"]+)".*/\1/')
            CURRENT_MODEL=$(grep '"ANTHROPIC_MODEL"' "$SETTINGS_JSON" | sed -E 's/.*"ANTHROPIC_MODEL": ?"([^"]+)".*/\1/')
        else
            IS_CUSTOM_API=false
            CURRENT_URL=""
            CURRENT_MODEL=""
        fi
    fi
}

# 获取状态与版本信息
get_status() {
    if command -v claude &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(claude -v 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="未知版本"
        claude_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        version_info_err="-"
        claude_version="${RED}-${RESET}"
    fi

    # 刷新并检查是否配置了自定义 API
    refresh_env
    if [ "$IS_CUSTOM_API" = true ]; then
        api_status="${YELLOW}自定义中转 (${CURRENT_MODEL:-中转})${RESET}"
    else
        api_status="${GREEN}官方默认${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Claude Code 管理面板   ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $claude_version"
    echo -e "${GREEN}API  :${RESET} $api_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Claude Code${RESET}"
    echo -e "${GREEN}2. 在当前目录启动${RESET}"
    echo -e "${GREEN}3. 指定项目路径启动${RESET}"
    echo -e "${GREEN}4. 登录/切换账户 (官方模式)${RESET}"
    echo -e "${GREEN}5. 设置自定义 API 模型/中转网关${RESET}"
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
        clear
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
    # 替换可能存在的 ~ 为全局家目录路径
    target_path="${target_path/#\~/$HOME}"
    
    if [ -d "$target_path" ]; then
        echo -e "${GREEN}正在切换到 $target_path 并启动 Claude Code...${RESET}"
        clear
        cd "$target_path" && claude
    else
        echo -e "${RED}路径不存在或无效，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 登录
login_claude() {
    if command -v claude &> /dev/null; then
        echo -e "\n${YELLOW}正在启动登录程序...${RESET}"
        echo -e "提示：如果已经在会话中，直接输入 /login 即可"
        claude -c "/login" 2>/dev/null || claude
    else
        echo -e "\n${RED}未检测到已安装的 Claude Code。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 5. 配置高级自定义 API 模型与路径
config_custom_api() {
    local SETTINGS_JSON="$HOME/.claude/settings.json"
    local ONBOARDING_JSON="$HOME/.claude.json"
    mkdir -p "$HOME/.claude"
    
    refresh_env
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      自定义 API 配置管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前 Base URL:${RESET} ${YELLOW}${CURRENT_URL:-官方默认}${RESET}"
    echo -e "${GREEN}当前主核心模型:${RESET} ${YELLOW}${CURRENT_MODEL:-官方默认}${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}1. 快捷设置代理模型配置${RESET}"
    echo -e "${GREEN}2. 清除自定义配置（恢复官方默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}1/4. 请输入自定义 API 中转地址/网关 (例如: https://api.yourproxy.com/v1):${RESET}"
            echo -ne "   地址: " && read input_url
            
            echo -e "\n${YELLOW}2/4. 请输入你的 API Key / 密钥 Token:${RESET}"
            echo -ne "   秘钥: " && read input_key

            echo -e "\n${YELLOW}3/4. 请输入主核心自定义模型 ID:${RESET}"
            echo -ne "   (例如: claude-3-5-sonnet-20241022 或 deepseek-chat)\n   模型名: " && read input_model

            echo -e "\n${YELLOW}4/4. 请输入子代理自定义模型 ID (TTP/工具执行模型):${RESET}"
            echo -ne "   (例如: claude-3-5-haiku-20241022 或 deepseek-coder)\n   模型名: " && read input_submodel

            if [ -n "$input_url" ] && [ -n "$input_key" ] && [ -n "$input_model" ] && [ -n "$input_submodel" ]; then
                
                # 1. 强行注入官方免登补丁
                cat << EOF > "$ONBOARDING_JSON"
{
  "hasCompletedOnboarding": true
}
EOF

                # 2. 严格按照全新的标准格式写入本地 settings.json
                cat << EOF > "$SETTINGS_JSON"
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "ANTHROPIC_BASE_URL": "$input_url",
    "ANTHROPIC_API_KEY": "$input_key",
    "ANTHROPIC_MODEL": "$input_model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "$input_submodel"
  }
}
EOF
                # 运行时环境变量同步清理，防止混淆环境
                unset CLAUDE_BASE_URL ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

                echo -e "\n${GREEN}========================================${RESET}"
                echo -e "${GREEN}✔ 配置成功！${RESET}"
                echo -e "${GREEN}✔ 已写入全新的 schema 校验标准配置！${RESET}"
                echo -e "${GREEN}========================================${RESET}"
            else
                echo -e "${RED}所有输入均不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            # 恢复默认空设置格式
            cat << EOF > "$SETTINGS_JSON"
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {}
}
EOF
            rm -f "$ONBOARDING_JSON"
            echo -e "${GREEN}✔ 已彻底清除自定义配置，成功恢复官方初始状态。${RESET}"
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
        claude update || npm update -g @anthropic-ai/claude-code
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
        echo -e "${YELLOW}[步骤 1/2] 正在删除主程序可执行文件及全局依赖...${RESET}"
        rm -f ~/.local/bin/claude
        rm -rf ~/.local/share/claude
        echo -e "${GREEN}✔ 主程序卸载成功。${RESET}"
        
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
