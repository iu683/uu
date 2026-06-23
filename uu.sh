#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# OpenCode 官方全局配置文件路径
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.json"
OPENCODE_AUTH_FILE="$HOME/.local/share/opencode/auth.json"

# 临时和永久确保当前脚本进程能找到最新的 PATH
export PATH="$HOME/.local/bin:/root/.local/bin:$PATH"

# 获取状态与版本信息
get_status() {
    if command -v opecode &> /dev/null; then
        status="${GREEN}已安装${RESET}"
        version_info=$(opecode -v 2>/dev/null || opecode --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        opecode_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        opecode_version="${RED}-${RESET}"
    fi

    # 检查凭据文件和配置文件
    if [ -f "$OPENCODE_AUTH_FILE" ]; then
        auth_status="${GREEN}已连接 (auth.json 存在)${RESET}"
    else
        auth_status="${RED}未连接${RESET}"
    fi

    if [ -f "$OPENCODE_CONFIG_FILE" ]; then
        config_status="${YELLOW}已配置 (opencode.json 存在)${RESET}"
    else
        config_status="${GREEN}官方默认${RESET}"
    fi
}

# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  OpenCode CLI  管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $opecode_version"
    echo -e "${GREEN}凭据 :${RESET} $auth_status"
    echo -e "${GREEN}配置 :${RESET} $config_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 OpenCode${RESET}"
    echo -e "${GREEN}2. 在当前目录启动${RESET}"
    echo -e "${GREEN}3. 在指定路径启动${RESET}"
    echo -e "${GREEN}4. 连接模型提供商 (/connect)${RESET}"
    echo -e "${GREEN}5. 配置自定义提供商/Base URL/API Key (JSON)${RESET}"
    echo -e "${GREEN}6. 更新 OpenCode${RESET}"
    echo -e "${GREEN}7. 卸载 OpenCode${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装
install_opecode() {
    echo -e "\n${YELLOW}[1/2] 正在通过官方通道安装 OpenCode...${RESET}"
    curl -fsSL https://opencode.ai/install | bash

    echo -e "\n${YELLOW}[2/2] 正在检测并安装 bubblewrap 沙箱依赖...${RESET}"
    if command -v bwrap &> /dev/null; then
        echo -e "${GREEN}✔ 检测到系统已存在 bubblewrap，跳过安装。${RESET}"
    else
        if command -v apt-get &> /dev/null; then
            echo -e "${YELLOW}检测到 Debian/Ubuntu 系统，正在使用 apt 安装...${RESET}"
            apt-get update && apt-get install -y bubblewrap
        elif command -v dnf &> /dev/null; then
            echo -e "${YELLOW}检测到 RedHat/Fedora/CentOS 系统，正在使用 dnf 安装...${RESET}"
            dnf install -y bubblewrap
        elif command -v yum &> /dev/null; then
            echo -e "${YELLOW}检测到 CentOS 旧版本系统，正在使用 yum 安装...${RESET}"
            yum install -y bubblewrap
        else
            echo -e "${RED}❌ 未能识别您的包管理器，请手动执行安装命令：apt/dnf install bubblewrap${RESET}"
        fi
    fi

    echo -e "\n${GREEN}✔ 所有安装与沙箱环境修复完成！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current() {
    if command -v opecode &> /dev/null; then
        echo -e "\n${GREEN}正在当前目录启动 OpenCode...${RESET}"
        opecode
    else
        echo -e "\n${RED}未检测到 opecode 命令，请先执行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 3. 指定路径启动
start_path() {
    echo -e "\n"
    echo -ne "${GREEN}请输入你的项目绝对路径: ${RESET}"
    read target_path
    if [ -d "$target_path" ]; then
        echo -e "${GREEN}正在切换到 $target_path 并启动 OpenCode...${RESET}"
        cd "$target_path" && opecode
    else
        echo -e "${RED}路径不存在，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 连接/添加 API 密钥
login_opecode() {
    if command -v opecode &> /dev/null; then
        echo -e "\n${YELLOW}正在调用 OpenCode 凭据连接程序 (/connect)...${RESET}"
        echo -e "${YELLOW}提示：若要使用第三方兼容提供商，请向下滚动到 'Other' 并设置自定义 ID。${RESET}\n"
        opecode /connect
    else
        echo -e "\n${RED}未检测到已安装的 OpenCode。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 5. 配置高级自定义提供商 JSON
config_custom_api() {
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}    OpenCode 提供商配置管理      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 快捷设置官方预设提供商的 Base URL (如 anthropic)${RESET}"
    echo -e "${GREEN}2. 注入第三方 OpenAI 兼容提供商 (支持硬编码 API Key)${RESET}"
    echo -e "${GREEN}3. 清除自定义 JSON 配置（恢复默认）${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read api_choice

    # 确保全局配置目录存在
    mkdir -p "$OPENCODE_CONFIG_DIR"

    case $api_choice in
        1)
            echo -e "\n${YELLOW}请输入官方提供商标识 (例如: anthropic, openai, deepseek):${RESET}"
            echo -ne "   提供商标识: "
            read input_provider
            [ -z "$input_provider" ] && input_provider="anthropic"
            
            echo -e "\n${YELLOW}请输入该提供商的自定义 Base URL:${RESET}"
            echo -ne "   Base URL: "
            read input_url
            
            if [ -n "$input_url" ]; then
                cat << EOF > "$OPENCODE_CONFIG_FILE"
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "$input_provider": {
      "options": {
        "baseURL": "$input_url"
      }
    }
  }
}
EOF
                echo -e "\n${GREEN}✔ 官方预设扩展配置已成功写入：$OPENCODE_CONFIG_FILE${RESET}"
            else
                echo -e "${RED}输入不能为空，取消设置。${RESET}"
            fi
            ;;
        2)
            echo -e "\n${YELLOW}1/6. 请输入提供商的唯一 ID (需与 /connect 一致；如选择直接填 Key 则可自定义):${RESET}"
            echo -ne "   提供商 ID (例如: myprovider): "
            read custom_id
            [ -z "$custom_id" ] && custom_id="myprovider"

            echo -e "\n${YELLOW}2/6. 请输入该提供商的展示名称 (Display Name):${RESET}"
            echo -ne "   展示名称: "
            read custom_name
            [ -z "$custom_name" ] && custom_name="My AI Provider"

            echo -e "\n${YELLOW}3/6. 请输入 API 基础端点地址 (Base URL):${RESET}"
            echo -ne "   Base URL: "
            read custom_url
            
            echo -e "\n${YELLOW}4/6. [可选] 是否直接在此硬编码 API 密钥 (apiKey)？${RESET}"
            echo -e "   ${YELLOW}(直接回车则跳过，继续使用 /connect 存储的凭据)${RESET}"
            echo -ne "   API Key / Token: "
            read custom_key

            echo -e "\n${YELLOW}5/6. 请输入你要映射的模型 ID (API 调用的实际模型名):${RESET}"
            echo -ne "   模型 ID (例如: deepseek-chat): "
            read model_id
            [ -z "$model_id" ] && model_id="custom-model"

            echo -e "\n${YELLOW}6/6. 请输入该模型在 OpenCode UI 中的展示名称:${RESET}"
            echo -ne "   模型展示名称: "
            read model_name
            [ -z "$model_name" ] && model_name="My Custom Model"

            if [ -n "$custom_url" ]; then
                # 核心逻辑：根据是否输入了 Key，动态构建 options 内部的 JSON 字符串
                if [ -n "$custom_key" ]; then
                    options_json="\"baseURL\": \"$custom_url\", \"apiKey\": \"$custom_key\""
                else
                    options_json="\"baseURL\": \"$custom_url\""
                fi

                cat << EOF > "$OPENCODE_CONFIG_FILE"
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "$custom_id": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "$custom_name",
      "options": {
        $options_json
      },
      "models": {
        "$model_id": {
          "name": "$model_name"
        }
      }
    }
  }
}
EOF
                echo -e "\n${GREEN}✔ 兼容提供商 JSON 配置文件已成功覆盖生成！${RESET}"
                [ -n "$custom_key" ] && echo -e "${YELLOW}🔑 已成功在 options 中嵌入明文 API Key。${RESET}"
                echo -e "${YELLOW}查看路径: $OPENCODE_CONFIG_FILE${RESET}"
            else
                echo -e "${RED}由于 Base URL 不能为空，配置已被取消。${RESET}"
            fi
            ;;
        3)
            if [ -f "$OPENCODE_CONFIG_FILE" ]; then
                rm -f "$OPENCODE_CONFIG_FILE"
                echo -e "${GREEN}✔ 已彻底删除全局配置 $OPENCODE_CONFIG_FILE，恢复默认。${RESET}"
            else
                echo -e "${YELLOW}当前已经是默认状态。${RESET}"
            fi
            ;;
        *)
            return
            ;;
    esac
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 更新
update_opecode() {
    echo -e "\n${YELLOW}正在检查并更新 OpenCode...${RESET}"
    opencode upgrade
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 7. 整合卸载
uninstall_opecode_flow() {
    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要卸载 OpenCode 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # 第一步：卸载程序
        echo -e "${YELLOW}[步骤 1/3] 正在删除主程序可执行文件与缓存...${RESET}"
        rm -f ~/.local/bin/opecode
        rm -rf ~/.local/share/opencode
        echo -e "${GREEN}✔ 主程序及本地缓存卸载成功。${RESET}"
        
        # 第二步：清除配置文件
        echo -e "\n${RED}[步骤 2/3] 是否清除配置文件与连接凭据(auth.json)？${RESET}"
        echo -e "${RED}注意：此操作将清除所有已连接的 API 密钥及代理设置！${RESET}"
        echo -ne "${RED}是否清除？(y/n): ${RESET}"
        read ans_config
        if [ "$ans_config" = "y" ] || [ "$ans_config" = "Y" ]; then
            echo -e "${YELLOW}正在清除全局配置文件与凭据...${RESET}"
            rm -rf "$OPENCODE_CONFIG_DIR"
            rm -rf "$HOME/.local/share/opencode"
            echo -e "${GREEN}✔ 配置文件与凭据已彻底干净！${RESET}"
        else
            echo -e "${YELLOW}已保留配置文件与凭据。你可以随时重新安装并恢复使用。${RESET}"
        fi

        # 第三步：清除沙箱依赖（bubblewrap）
        echo -e "\n${RED}[步骤 3/3] 是否连同 bubblewrap 沙箱依赖包一起卸载？${RESET}"
        echo -ne "${RED}若该机器无其他沙箱业务，建议执行卸载。(y/n): ${RESET}"
        read ans_bwrap
        if [ "$ans_bwrap" = "y" ] || [ "$ans_bwrap" = "Y" ]; then
            echo -e "${YELLOW}正在清理系统的 bubblewrap 组件...${RESET}"
            if command -v apt-get &> /dev/null; then
                apt-get autoremove -y bubblewrap
            elif command -v dnf &> /dev/null; then
                dnf remove -y bubblewrap
            elif command -v yum &> /dev/null; then
                yum remove -y bubblewrap
            fi
            echo -e "${GREEN}✔ 沙箱组件卸载成功。${RESET}"
        else
            echo -e "${YELLOW}已保留系统的 bubblewrap。${RESET}"
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
        1) install_opecode ;;
        2) start_current ;;
        3) start_path ;;
        4) login_opecode ;;
        5) config_custom_api ;;
        6) update_opecode ;;
        7) uninstall_opecode_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
