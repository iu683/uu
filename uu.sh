#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# Codex 官方全局配置文件路径
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG_FILE="$CODEX_CONFIG_DIR/config.toml"

# 临时和永久确保当前脚本进程能找到最新的 PATH
export PATH="$HOME/.local/bin:/root/.local/bin:$HOME/.codex/packages/standalone/releases/0.142.0-x86_64-unknown-linux-musl:$PATH"

# 获取状态与版本信息
get_status() {
    if command -v codex &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(codex -v 2>/dev/null || codex --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        codex_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装 (请执行选项 1)${RESET}"
        codex_version="${RED}-${RESET}"
    fi

    # 检查 TOML 配置文件看当前在使用什么 Provider
    if [ -f "$CODEX_CONFIG_FILE" ] && grep -q 'model_provider = "custom_proxy"' "$CODEX_CONFIG_FILE"; then
        api_status="${YELLOW}自定义中转 (TOML 托管)${RESET}"
    else
        api_status="${GREEN}官方默认/ChatGPT账户${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Codex CLI TOML管理面板  ◈    ${RESET}"
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
    echo -e "${GREEN}安装与修复完成！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current() {
    if command -v codex &> /dev/null; then
        echo -e "\n${GREEN}正在当前目录启动 Codex...${RESET}"
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
        cd "$target_path" && codex
    else
        echo -e "${RED}路径不存在，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 登录
login_codex() {
    if command -v codex &> /dev/null; then
        echo -e "\n${YELLOW}正在启动远程/无头设备专属登录程序...${RESET}"
        codex login --device-auth || codex login || codex
    else
        echo -e "\n${RED}未检测到已安装的 Codex。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 5. 配置高级自定义 API 模型路径和 Key (精准操控 TOML)
config_custom_api() {
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}      自定义 API 配置管理       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 注入自定义中转 / 代理模型配置 (自动写配置文件)${RESET}"
    echo -e "${GREEN}2. 清除自定义配置（恢复官方默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    case $api_choice in
        1)
            echo -e "\n${YELLOW}1/4. 请输入自定义 API 中转地址/网关:${RESET}"
            echo -ne "   地址: "
            read input_url
            
            echo -e "\n${YELLOW}2/4. 请输入你的 API Key / Token:${RESET}"
            echo -ne "   秘钥: "
            read input_key
            
            echo -e "\n${YELLOW}3/4. 请输入你想指定的主核心模型:${RESET}"
            echo -ne "   (直接回车默认使用: gpt-5)\n   模型名: "
            read input_model
            [ -z "$input_model" ] && input_model="gpt-5"

            if [ -n "$input_url" ] && [ -n "$input_key" ]; then
                # 确保配置目录存在
                mkdir -p "$CODEX_CONFIG_DIR"

                # 1. 强行将 Key 写入当前用户的临时环境变量文件中，或者直接导出
                export CUSTOM_PROXY_API_KEY="$input_key"
                # 为了持久化，顺便写进用户的 shell 配置文件
                local shell_config="$HOME/.bashrc"
                [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ] && shell_config="$HOME/.zshrc"
                sed -i '/CUSTOM_PROXY_API_KEY/d' "$shell_config" 2>/dev/null
                echo "export CUSTOM_PROXY_API_KEY=\"$input_key\"" >> "$shell_config"

                # 2. 生成完全符合官方规范的 config.toml 覆盖全局
                cat << EOF > "$CODEX_CONFIG_FILE"
# 顶层全局调用配置
model_provider = "custom_proxy"
model = "$input_model"
model_context_window = 200000
model_reasoning_effort = "medium"
sandbox_mode = "workspace-write"
approval_policy = "on-request"

# 自定义中转 Provider 块
[model_providers.custom_proxy]
name = "Custom Proxy Gateway"
base_url = "$input_url"
env_key = "CUSTOM_PROXY_API_KEY"
EOF
                echo -e "\n${GREEN}✔ 恭喜！中转配置已成功写入 $CODEX_CONFIG_FILE${RESET}"
                echo -e "${YELLOW}🔑 环境变量 CUSTOM_PROXY_API_KEY 已成功同步写入 $shell_config${RESET}"
            else
                echo -e "${RED}输入不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            if [ -f "$CODEX_CONFIG_FILE" ]; then
                rm -f "$CODEX_CONFIG_FILE"
                echo -e "${GREEN}✔ 已彻底删除 $CODEX_CONFIG_FILE，恢复官方默认配置。${RESET}"
            else
                echo -e "${YELLOW}当前已经是官方默认状态。${RESET}"
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
    echo -e "\n${YELLOW}正在更新 Codex...${RESET}"
    curl -fsSL https://chatgpt.com/codex/install.sh | bash
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
