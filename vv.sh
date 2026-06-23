#!/bin/bash

# 标准 ANSI 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# 尝试在脚本内直接载入可能写入了环境路径的 bashrc 
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null
# 增强 PATH 搜索：同时兼容普通用户、root 用户以及自定义的 root 安装路径
export PATH="$HOME/.local/bin:/root/.local/bin:/root/.opencode/bin:$PATH"

# 动态定位 OpenCode 实际安装与配置路径
get_paths() {
    OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
    OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.json"
    OPENCODE_AUTH_FILE="$HOME/.local/share/opencode/auth.json"
    REAL_EXEC_PATH=$(command -v opencode 2>/dev/null)

    # 如果检测到 opencode 挂在 root 旗下，重定向路径定义
    if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
        OPENCODE_CONFIG_DIR="/root/.config/opencode"
        OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.json"
        OPENCODE_AUTH_FILE="/root/.local/share/opencode/auth.json"
    fi
}




# 获取状态与版本信息
get_status() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        status="${GREEN}已安装${RESET}"
        version_info=$(opencode -v 2>/dev/null || opencode --version 2>/dev/null | head -n 1)
        [ -z "$version_info" ] && version_info="已就绪"
        opencode_version="${YELLOW}${version_info}${RESET}"
    else
        status="${RED}未安装${RESET}"
        opencode_version="${RED}-${RESET}"
    fi

    if sudo [ -f "$OPENCODE_CONFIG_FILE" ] 2>/dev/null; then
        config_status="${YELLOW}已配置${RESET}"
    else
        config_status="${GREEN}官方默认${RESET}"
    fi
}


# 菜单面板
show_menu() {
    clear
    get_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  OpenCode CLI 管理面板  ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} $opencode_version"
    echo -e "${GREEN}配置 :${RESET} $config_status"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 在当前目录启动${RESET}"
    echo -e "${GREEN}3. 在指定路径启动${RESET}"
    echo -e "${GREEN}4. 连接模型提供商${RESET}"
    echo -e "${GREEN}5. 配置自定义提供商${RESET}"
    echo -e "${GREEN}6. 更新${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
}

# 1. 安装
install_opencode() {
    echo -e "\n${YELLOW}[1/2] 正在通过官方通道安装 OpenCode...${RESET}"
    curl -fsSL https://opencode.ai/install | bash
    
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null

    echo -e "\n${YELLOW}[2/2] 正在检测并安装 bubblewrap 沙箱依赖...${RESET}"
    if command -v bwrap &> /dev/null; then
        echo -e "${GREEN}✔ 检测到系统已存在 bubblewrap，跳过安装。${RESET}"
    else
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y bubblewrap
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y bubblewrap
        elif command -v yum &> /dev/null; then
            sudo yum install -y bubblewrap
        else
            echo -e "${RED}❌ 未能识别您的包管理器，请手动执行：sudo apt/dnf install bubblewrap${RESET}"
        fi
    fi

    echo -e "\n${GREEN}✔ 所有安装与沙箱环境修复完成！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 2. 当前目录启动
start_current() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        echo -e "\n${GREEN}正在启动 OpenCode...${RESET}"
        if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
            sudo "$REAL_EXEC_PATH"
        else
            opencode
        fi
    else
        echo -e "\n${RED}未检测到 opencode 命令，请先执行安装！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 3. 指定路径启动
start_path() {
    get_paths
    if [ -z "$REAL_EXEC_PATH" ]; then
        echo -e "\n${RED}未检测到已安装的 OpenCode。${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
        return
    fi

    echo -e "\n"
    echo -ne "${GREEN}请输入你的项目绝对路径: ${RESET}"
    read target_path
    if [ -d "$target_path" ]; then
        echo -e "${GREEN}正在切换到 $target_path 并启动 OpenCode...${RESET}"
        cd "$target_path" || return
        if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
            sudo "$REAL_EXEC_PATH"
        else
            opencode
        fi
    else
        echo -e "${RED}路径不存在，请检查后重试！${RESET}"
        echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
    fi
}

# 4. 连接/添加 API 密钥 (精准调用官方的 providers login)
login_opencode() {
    get_paths
    if [ -n "$REAL_EXEC_PATH" ]; then
        echo -e "\n${YELLOW}正在调用 OpenCode 凭据登录程序 (providers login)...${RESET}"
        if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
            sudo "$REAL_EXEC_PATH" providers login
        else
            opencode providers login
        fi
    else
        echo -e "\n${RED}未检测到已安装的 OpenCode。${RESET}"
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 5. 配置高级自定义提供商 JSON (标准 JSON 修复版)
config_custom_api() {
    get_paths
    echo -e "\n${GREEN}================================${RESET}"
    echo -e "${GREEN}OpenCode 第三方提供商配置      ${RESET}"
    echo -e "\n${RED}注意：此处的 '提供商 ID' 必须与你在第 4 项 (Other) 中输入的 ID 完全一致！${RESET}"
    
    echo -ne "${YELLOW}1/5. 请输入提供商唯一 ID (例如: myprovider): ${RESET}"
    read custom_id
    [ -z "$custom_id" ] && custom_id="myprovider"

    echo -ne "${YELLOW}2/5. 请输入在 UI 中显示的的展示名称 (例如: 聚合AI): ${RESET}"
    read custom_name
    [ -z "$custom_name" ] && custom_name="My Custom AI"

    echo -ne "${YELLOW}3/5. 请输入 API 基础端点 (Base URL): ${RESET}"
    read custom_url
    [ -z "$custom_url" ] && return

    echo -ne "${YELLOW}4/5. 请输入 API 调用的实际模型 ID (例如: deepseek-chat): ${RESET}"
    read model_id
    [ -z "$model_id" ] && model_id="custom-model"

    echo -ne "${YELLOW}5/5. 请输入该模型在 UI 中的展示名称 (例如: DeepSeek V3): ${RESET}"
    read model_name
    [ -z "$model_name" ] && model_name="Custom Model"

    echo -ne "\n${YELLOW}[可选] 是否直接在此 JSON 中固定 API 密钥？\n(直接回车跳过，则使用第 4 项通过 login 绑定的密钥): ${RESET}"
    read custom_key

    # 动态构建 options 部分的 JSON 字符串
    if [ -n "$custom_key" ]; then
        options_json="\"baseURL\": \"$custom_url\", \"apiKey\": \"$custom_key\""
    else
        options_json="\"baseURL\": \"$custom_url\""
    fi

    # 🛠️ 核心修复：使用极其安全的 EOF 方式写入，彻底杜绝任何反斜杠转义引发的 JSON 语法错误
    json_content=$(cat <<EOF
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
          "name": "$model_name",
          "limit": {
            "context": 200000,
            "output": 65536
          }
        }
      }
    }
  }
}
EOF
)

    # 全局双向、双文件名强力灌注覆盖
    mkdir -p "$HOME/.config/opencode"
    sudo mkdir -p "/root/.config/opencode" 2>/dev/null

    echo "$json_content" > "$HOME/.config/opencode/opencode.json"
    echo "$json_content" > "$HOME/.config/opencode/config.json"
    echo "$json_content" | sudo tee "/root/.config/opencode/opencode.json" > /dev/null
    echo "$json_content" | sudo tee "/root/.config/opencode/config.json" > /dev/null

    echo -e "\n${GREEN}✔ 兼容提供商配置已成功生成，并且完全符合标准 JSON 规范！${RESET}"
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 6. 更新
update_opencode() {
    get_paths
    echo -e "\n${YELLOW}正在检查并更新 OpenCode...${RESET}"
    if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
        sudo curl -fsSL https://opencode.ai/install | bash
    else
        curl -fsSL https://opencode.ai/install | bash
    fi
    echo -ne "\n${GREEN}按回车键返回主菜单...${RESET}" && read
}

# 7. 整合卸载 (修正为优先调用官方原生的 uninstall 机制)
uninstall_opencode_flow() {
    get_paths
    echo -e "\n${RED}准备进入卸载流程...${RESET}"
    echo -ne "${RED}确定要完全卸载 OpenCode 主程序吗？(y/n): ${RESET}"
    read ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        echo -e "${YELLOW}[步骤 1/2] 正在调用官方原生引擎执行卸载...${RESET}"
        if [ -n "$REAL_EXEC_PATH" ]; then
            if [[ "$REAL_EXEC_PATH" == "/root/"* ]]; then
                sudo "$REAL_EXEC_PATH" uninstall
            else
                opencode uninstall
            fi
        fi

        # 强力双向扫尾清理
        rm -f ~/.local/bin/opencode
        rm -rf ~/.local/share/opencode
        rm -rf "$HOME/.config/opencode"
        
        sudo rm -f /root/.local/bin/opencode
        sudo rm -rf /root/.opencode
        sudo rm -rf /root/.local/share/opencode
        sudo rm -rf "/root/.config/opencode"

        echo -e "${GREEN}✔ 核心程序、本地缓存与配置文件已全部净化！${RESET}"

        # 第二步：清除沙箱依赖
        echo -e "\n${RED}[步骤 2/2] 是否连同 bubblewrap 沙箱依赖包一起卸载？${RESET}"
        echo -ne "${RED}若该机器无其他沙箱业务，建议卸载。(y/n): ${RESET}"
        read ans_bwrap
        if [ "$ans_bwrap" = "y" ] || [ "$ans_bwrap" = "Y" ]; then
            echo -e "${YELLOW}正在清理系统的 bubblewrap 组件...${RESET}"
            if command -v apt-get &> /dev/null; then
                sudo apt-get autoremove -y bubblewrap
            elif command -v dnf &> /dev/null; then
                sudo dnf remove -y bubblewrap
            elif command -v yum &> /dev/null; then
                sudo yum remove -y bubblewrap
            fi
            echo -e "${GREEN}✔ 系统沙箱组件卸载成功。${RESET}"
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
        1) install_opencode ;;
        2) start_current ;;
        3) start_path ;;
        4) login_opencode ;;
        5) config_custom_api ;;
        6) update_opencode ;;
        7) uninstall_opencode_flow ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新选择！${RESET}"; sleep 1 ;;
    esac
done
