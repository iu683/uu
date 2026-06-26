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

# 5. 配置高级自定义 API 模型与路径 (严格复刻通用无错版)
config_custom_api() {
    local SETTINGS_JSON="$HOME/.claude/settings.json"
    local ONBOARDING_JSON="$HOME/.claude.json"
    mkdir -p "$HOME/.claude"
    
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      通用自定义 API 配置       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 快捷一键生成通用持久化代理环境${RESET}"
    echo -e "${GREEN}2. 清除自定义配置（恢复官方默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}1/3. 请输入自定义 API 中转地址/网关:${RESET}"
            echo -ne "   (例如: https://api.deepseek.com/anthropic)\n   地址: "
            read input_url
            
            echo -e "\n${YELLOW}2/3. 请输入你的 API Key / 密钥 Token:${RESET}"
            echo -ne "   秘钥: "
            read input_key

            echo -e "\n${YELLOW}3/3. 请输入你想指定的目标模型名称:${RESET}"
            echo -ne "   (例如: DeepSeek-V4-Pro 或 gpt-5.4)\n   模型名: "
            read input_model

            if [ -n "$input_url" ] && [ -n "$input_key" ] && [ -n "$input_model" ]; then
                
                # 自动注入免登录验证凭证
                cat << EOF > "$ONBOARDING_JSON"
{
  "hasCompletedOnboarding": true
}
EOF

                # 【100% 严格复刻你发出来的最终成功模板】
                # 只在内层 env 里保留最纯净的 5 个核心基础字段，不夹杂任何多余结构
                cat << EOF > "$SETTINGS_JSON"
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "$input_key",
    "ANTHROPIC_BASE_URL": "$input_url",
    "ANTHROPIC_MODEL": "$input_model",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
EOF
                # 物理清理可能引起冲突的老变量和局部历史文件
                unset CLAUDE_BASE_URL ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
                unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
                unset CLAUDE_CODE_SUBAGENT_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_CUSTOM_MODEL_OPTION

                echo -e "\n${GREEN}✔ 成功！已严格按照最新成功模板固化配置至: $SETTINGS_JSON${RESET}"
            else
                echo -e "${RED}所有输入均不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            cat << EOF > "$SETTINGS_JSON"
{
  "env": {}
}
EOF
            rm -f "$ONBOARDING_JSON"
            echo -e "${GREEN}✔ 已彻底清除自定义配置，成功恢复初始 settings.json。${RESET}"
            ;;
        *)
            return
            ;;
    esac
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
