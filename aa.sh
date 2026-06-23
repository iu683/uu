#!/bin/bash
# ========================================
# CodeWhale 管理面板
# ========================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

CONFIG_PATH="$HOME/.codewhale/config.toml"

# 默默在后台把全局安装的 bin 路径以及常用的 Node 路径加进去，防止找不到命令
ensure_env_path() {
    # 兼容通过普通包管理器或 NodeSource 安装的路径
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    
    if command -v npm &> /dev/null; then
        local npm_bin
        npm_bin=$(npm config get prefix 2>/dev/null)/bin
        if [[ -d "$npm_bin" && ":$PATH:" != *":$npm_bin:"* ]]; then
            export PATH="$npm_bin:$PATH"
        fi
    fi
}

get_status() {
    ensure_env_path
    if command -v codewhale &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(codewhale --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        codewhale_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        codewhale_version="${RED}-${RESET}"
    fi

    if [[ -f "$CONFIG_PATH" ]]; then
        current_model=$(grep 'default_text_model' "$CONFIG_PATH" | cut -d '"' -f 2)
        [ -z "$current_model" ] && current_model="已配置"
        api_status="${GREEN}${current_model}${RESET}"
    else
        api_status="${RED}未设置${RESET}"
    fi
}

show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  CodeWhale  管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $codewhale_version"
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

# 1. 安装 (支持自动补全 Node.js / npm 依赖)
install_app() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}❌ 错误: 安装需要 root 权限，请使用 sudo 运行本脚本！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return 1
    fi

    # 检测并安装 Node.js 与 npm 核心运行环境
    if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
        echo -e "\n${YELLOW}检测到系统未安装 Node.js/npm 运行环境，正在尝试自动安装...${RESET}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y
            # 引入 NodeSource 安全稳定的 LTS 源
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
            apt-get install -y nodejs
        elif command -v dnf &> /dev/null; then
            dnf module json -y nodejs:lts &>/dev/null
            dnf install -y nodejs npm
        elif command -v yum &> /dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
            yum install -y nodejs
        else
            echo -e "${RED}❌ 无法识别的系统包管理器，请手动安装 Node.js 后再试！${RESET}"
            echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
            return 1
        fi
    fi

    # 二次验证 Node 环境是否成功就绪
    ensure_env_path
    if ! command -v npm &> /dev/null; then
        echo -e "\n${RED}❌ Node.js 环境安装失败，请手动检查系统包源。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return 1
    fi

    echo -e "\n${YELLOW}正在补充系统基础编译依赖项 (C++ 模块构建需求)...${RESET}"
    if command -v apt-get &> /dev/null; then
        apt-get install -y build-essential pkg-config libdbus-1-dev curl
    elif command -v dnf &> /dev/null; then
        dnf install -y gcc pkgconfig dbus-devel curl
    elif command -v yum &> /dev/null; then
        yum install -y gcc pkgconfig dbus-devel curl
    fi

    echo -e "\n${YELLOW}正在通过 npm 全局安装 CodeWhale...${RESET}"
    npm install -g codewhale

    local npm_bin
    npm_bin=$(npm config get prefix 2>/dev/null)/bin
    if ! grep -q "$npm_bin" "$HOME/.bashrc" 2>/dev/null; then
        echo "export PATH=\"\$PATH:$npm_bin\"" >> "$HOME/.bashrc"
    fi
    ensure_env_path

    echo -e "\n${GREEN}✔ 安装成功！正在执行首次运行诊断...${RESET}"
    codewhale doctor
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current_dir() {
    ensure_env_path
    if ! command -v codewhale &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装程序！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi
    echo -e "\n${GREEN}正在唤醒 CLI 界面...${RESET}"
    echo -e "${YELLOW}💡 提示：进入会话后，可使用以下快捷斜杠指令：${RESET}"
    echo -e "   /provider 或 /model  -> 中途切换路由/模型"
    echo -e "   /restore             -> 回滚上一轮对话 (Side-Git快照)"
    echo -e "   /config              -> 编辑运行时设置与状态条"
    echo -e "   ! <command>          -> 正常调用沙箱 Shell 命令\n"
    
    DEEPSEEK_ALLOW_INSECURE_HTTP=1 codewhale
}

# 3. 指定路径启动
start_spec_dir() {
    ensure_env_path
    if ! command -v codewhale &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装程序！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi
    echo -e "\n${YELLOW}请输入目标工作绝对路径:${RESET}"
    echo -ne " 路径: "
    read -r target_path
    if [ -d "$target_path" ]; then
        echo -e "\n${GREEN}正在切换目录并唤醒 CLI 界面...${RESET}\n"
        cd "$target_path" || return
        DEEPSEEK_ALLOW_INSECURE_HTTP=1 codewhale
    else
        echo -e "\n${RED}❌ 路径不正确或不存在。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 登录/切换账户
account_auth() {
    ensure_env_path
    if ! command -v codewhale &> /dev/null; then
        echo -e "\n${RED}❌ 请先执行选项 1 安装程序！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi
    
    echo -e "\n${YELLOW}--- 登录与切换通道账户 ---${RESET}"
    echo "1. 登录 DeepSeek 官方通道"
    echo "2. 登录 Anthropic (Claude) 通道"
    echo "3. 登录 OpenRouter 通道"
    echo "4. 登录 Moonshot (Kimi) 通道"
    echo "5. 切换到本地免 Key 运行时 (Ollama / vLLM / sglang)"
    echo "6. 查看当前通道鉴权状态 (Auth Status)"
    echo -ne "请选择选项 [1-6]: "
    read -r auth_choice

    case $auth_choice in
        1) codewhale auth set --provider deepseek ;;
        2) codewhale auth set --provider anthropic ;;
        3) codewhale auth set --provider openrouter ;;
        4) codewhale auth set --provider moonshot ;;
        5) 
            echo -e "\n${GREEN}已自动指向本地环回。请确保您的本地后端已启动（默认端口）。${RESET}"
            ;;
        6) 
            echo -e "\n${GREEN}--- 当前通道凭证状态 ---${RESET}"
            codewhale auth status 
            ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    
    echo -ne "\n${GREEN}操作完成。按回车键返回主菜单...${RESET}" && read
}

# 5. 设置自定义API模型/中转
config_api() {
    mkdir -p "$(dirname "$CONFIG_PATH")"
    echo -e "\n${YELLOW}--- 快速自定义 API/中转网关 ---${RESET}"
    echo -ne "1. 请输入中转网关 Base URL: "
    read -r g_url
    echo -ne "2. 请输入你的 API 密钥 (API Key): "
    read -r g_key
    echo -ne "3. 请输入默认模型 ID (例如 qwen-plus 或 deepseek-chat): "
    read -r g_model

    {
        echo "provider = \"openai\""
        echo "default_text_model = \"$g_model\""
        echo ""
        echo "[providers.openai]"
        echo "api_key = \"$g_key\""
        echo "base_url = \"$g_url\""
    } > "$CONFIG_PATH"

    echo -e "\n${GREEN}✔ 配置文件已保存至 ~/.codewhale/config.toml${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 更新
update_app() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}❌ 错误: 更新需要 root 权限，请使用 sudo 运行本脚本！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return 1
    fi
    echo -e "\n${YELLOW}正在更新程序包...${RESET}"
    npm install -g codewhale@latest
    echo -ne "\n${GREEN}更新完毕。按回车键返回主菜单...${RESET}" && read
}

# 7. 卸载 (带配置文件清理的二次确认)
uninstall_app() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}❌ 错误: 卸载需要 root 权限，请使用 sudo 运行本脚本！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return 1
    fi

    # 第一次确认：卸载程序本体
    echo -ne "\n${RED}确定要卸载 CodeWhale 主程序吗？(y/n): ${RESET}"
    read -r ans1
    if [[ "$ans1" == "y" || "$ans1" == "Y" ]]; then
        npm uninstall -g codewhale &>/dev/null
        npm uninstall -g deepseek-tui &>/dev/null
        echo -e "${GREEN}✔ 主程序已成功卸载。${RESET}"

        # 第二次确认：询问是否清除所有配置文件和历史会话
        echo -e "\n${YELLOW}检测到本地残留有配置文件、密钥和会话快照。${RESET}"
        echo -ne "${RED}是否同步清理这些本地配置文件？(会清除历史记录) (y/n): ${RESET}"
        read -r ans2
        if [[ "$ans2" == "y" || "$ans2" == "Y" ]]; then
            rm -rf "$HOME/.codewhale" "$HOME/.deepseek" "/root/.codewhale" 2>/dev/null
            echo -e "${GREEN}✔ 残留配置文件已彻底清除。${RESET}"
        else
            echo -e "${YELLOW}ℹ 已保留您的历史会话与本地配置文件。${RESET}"
        fi
    else
        echo -e "${YELLOW}已取消卸载。${RESET}"
    fi

    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 主循环
while true; do
    show_menu
    read -r choice
    case $choice in
        1) install_app ;;
        2) start_current_dir ;;
        3) start_spec_dir ;;
        4) account_auth ;;
        5) config_api ;;
        6) update_app ;;
        7) uninstall_app ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
