#!/bin/bash
# ===============================
# ZeroClaw 高级管理菜单
# ===============================
export LANG=en_US.UTF-8

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

green() { echo -e "${GREEN}$1${RESET}"; }
yellow() { echo -e "${YELLOW}$1${RESET}"; }
red() { echo -e "${RED}$1${RESET}"; }
blue() { echo -e "${BLUE}$1${RESET}"; }

ZER0CLAW_DIR="/opt/ZeroClaw"
CONFIG_FILE="$HOME/.zeroclaw/config.toml"

# 检查命令是否存在
command_exists() {
    command -v "$1" &>/dev/null
}

# 安装 ZeroClaw + Rust + 系统依赖
install_zeroclaw() {
    if [ ! -d "$ZER0CLAW_DIR" ]; then
        green "开始安装 ZeroClaw..."
        git clone https://github.com/zeroclaw-labs/zeroclaw.git "$ZER0CLAW_DIR"
    else
        yellow "ZeroClaw 已经存在，跳过克隆。"
    fi

    cd "$ZER0CLAW_DIR" || exit
    green "执行 bootstrap 脚本安装 Rust 工具链和系统依赖..."
    ./bootstrap.sh --install-rust --install-system-deps
    green "ZeroClaw 安装完成！"
}

# 配置 Provider 和 API Key（支持自定义模型）
configure_provider() {
    read -p "请输入你的 CLI API Key: " api_key
    read -p "请输入 Provider URL（示例: custom:https://ai.eu.org/v1）: " provider
    read -p "请输入默认模型（回车使用 gemini-3-flash-preview）: " model
    model=${model:-gemini-3-flash-preview}   # 如果用户没输入，使用默认值

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
api_key = "$api_key"
default_provider = "$provider"
default_model = "$model"
EOF
    green "配置完成，保存路径：$CONFIG_FILE"
}

# 启动 ZeroClaw
start_zeroclaw() {
    if [ -f "$ZER0CLAW_DIR/start.sh" ]; then
        green "启动 ZeroClaw..."
        bash "$ZER0CLAW_DIR/start.sh"
    else
        red "未找到启动脚本，请先安装 ZeroClaw。"
    fi
}

# 停止 ZeroClaw
stop_zeroclaw() {
    if pgrep -f "ZeroClaw" >/dev/null 2>&1; then
        pkill -f "ZeroClaw"
        green "ZeroClaw 已停止。"
    else
        yellow "ZeroClaw 未运行。"
    fi
}

# 查看状态
status_zeroclaw() {
    if pgrep -f "ZeroClaw" >/dev/null 2>&1; then
        green "ZeroClaw 正在运行中"
    else
        yellow "ZeroClaw 未运行"
    fi
}

# 卸载 ZeroClaw
uninstall_zeroclaw() {
            rm -rf "$ZER0CLAW_DIR"
            green "ZeroClaw 已卸载！"
        else
            yellow "取消卸载。"
        fi
    else
        red "ZeroClaw 未安装。"
    fi
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}======  ZeroClaw 管理菜单 ========${RESET}"
    echo -e "${GREEN}[1] 安装 ZeroClaw（含Rust+系统依赖）${RESET}"
    echo -e "${GREEN}[2] 配置 Provider和API Key${RESET}"
    echo -e "${GREEN}[3] 启动 ZeroClaw${RESET}"
    echo -e "${GREEN}[4] 停止 ZeroClaw${RESET}"
    echo -e "${GREEN}[5] 查看状态${RESET}"
    echo -e "${GREEN}[6] 卸载 ZeroClaw${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    read -p "请输入选项: " choice
    case "$choice" in
        1) install_zeroclaw ;;
        2) configure_provider ;;
        3) start_zeroclaw ;;
        4) stop_zeroclaw ;;
        5) status_zeroclaw ;;
        6) uninstall_zeroclaw ;;
        0) exit 0 ;;
        *) red "无效选项，请重新输入！" ;;
    esac
    read -p "按任意键返回菜单..." temp
}

# 主循环
while true; do
    show_menu
done
