#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 自定义配置文件路径
ENV_FILE="$HOME/.claude_custom_env"

# 加载保存的自定义 API 配置
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

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
    if [ -n "$CLAUDE_BASE_URL" ] || [ -n "$ANTHROPIC_BASE_URL" ]; then
        api_status="${YELLOW}自定义中转${RESET}"
    else
        api_status="${GREEN}官方默认${RESET}"
    fi
}

# 导入自定义 API 环境变量到当前会话
export_custom_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        [ -n "$CLAUDE_BASE_URL" ] && export CLAUDE_BASE_URL="$CLAUDE_BASE_URL"
        [ -n "$ANTHROPIC_BASE_URL" ] && export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL"
        [ -n "$ANTHROPIC_API_KEY" ] && export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
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
    echo -e "${GREEN}1. 安装环境${RESET}"
    echo -e "${GREEN}2. 当前目录启动${RESET}"
    echo -e "${GREEN}3. 指定路径启动${RESET}"
    echo -e "${GREEN}4. 登录/切换账户${RESET}"
    echo -e "${GREEN}5. 设置自定义 API 模型/中转${RESET}"
    echo -e "${GREEN}6. 更新版本${RESET}"
    echo -e "${GREEN}7. 卸载清除工具${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装
install_claude() {
    echo -e "\n${YELLOW}正在通过官方脚本安装 Claude Code...${RESET}"
    curl -fsSL https://claude.ai/install.sh | bash
    echo -e "${GREEN}安装尝试完成。${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current() {
    if command -v claude &> /dev/null; then
        echo -e "\n${GREEN}正在当前目录启动 Claude Code...${RESET}"
        export_custom_env
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
        export_custom_env
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
        export_custom_env
        claude -c "/login" 2>/dev/null || claude
    else
        echo -e "\n${RED}未检测到已安装的 Claude Code。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 5. 配置自定义 API 模型路径和 Key
config_custom_api() {
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      自定义 API 配置管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "当前保存的 Base URL: ${YELLOW}${CLAUDE_BASE_URL:-${ANTHROPIC_BASE_URL:-官方默认}}${RESET}"
    echo -e "当前保存的 API Key:  ${YELLOW}${ANTHROPIC_API_KEY:+已设置 (********)}${RESET}${ANTHROPIC_API_KEY:-未设置}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "1. 修改/设置自定义 API 配置"
    echo -e "2. 清除自定义 API（恢复官方默认）"
    echo -e "0. 返回主菜单"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}请输入你的自定义 API 中转地址${RESET} (例如: https://api.your-proxy.com/v1): "
            read input_url
            echo -e "${YELLOW}请输入你的自定义 API Key${RESET} (例如: sk-ant-... 或中转Key): "
            read input_key

            if [ -n "$input_url" ] && [ -n "$input_key" ]; then
                # 写入配置文件，同时兼容新旧环境变量
                echo "export CLAUDE_BASE_URL=\"$input_url\"" > "$ENV_FILE"
                echo "export ANTHROPIC_BASE_URL=\"$input_url\"" >> "$ENV_FILE"
                echo "export ANTHROPIC_API_KEY=\"$input_key\"" >> "$ENV_FILE"
                echo -e "${GREEN}✔ 配置已成功保存在本地！启动时将自动生效。${RESET}"
            else
                echo -e "${RED}输入不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            if [ -f "$ENV_FILE" ]; then
                rm -f "$ENV_FILE"
                unset CLAUDE_BASE_URL
                unset ANTHROPIC_BASE_URL
                unset ANTHROPIC_API_KEY
                echo -e "${GREEN}✔ 已清除自定义配置，成功恢复官方默认配置。${RESET}"
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
    echo -e "\n${RED}⚠️ 准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 Claude Code 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载程序
        echo -e "${YELLOW}[步骤 1/2] 正在删除主程序可执行文件...${RESET}"
        rm -f ~/.local/bin/claude
        rm -rf ~/.local/share/claude
        echo -e "${GREEN}✔ 主程序卸载成功。${RESET}"
        
        # 第二步：清除配置文件
        echo -e "\n${RED}⚠️ [步骤 2/2] 是否需要连同配置文件、历史记录、自定义API及MCP设置一起清除？${RESET}"
        echo -e "${RED}注意：此操作不可逆，清除后所有本地历史将永久丢失！${RESET}"
        echo -ne "${RED}是否清除配置文件？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清除全局、本地及API配置文件...${RESET}"
            rm -rf ~/.claude
            rm -f ~/.claude.json
            rm -rf .claude
            rm -f .mcp.json
            rm -f "$ENV_FILE"  # 清理本地自定义API环境变量
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
