#!/bin/bash
# ========================================
# DeepSeek 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

ARCH=""

# ========================================
# 检查 root
# ========================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 用户运行${RESET}"
        exit 1
    fi
}

# ========================================
# 安装依赖
# ========================================
install_deps() {

    if command -v apt &>/dev/null; then
        apt update -y
        apt install -y curl wget ca-certificates
    elif command -v yum &>/dev/null; then
        yum install -y curl wget ca-certificates
    fi
}

# ========================================
# 检测架构
# ========================================
detect_arch() {

    case "$(uname -m)" in
        x86_64|amd64)
            ARCH="x64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $(uname -m)${RESET}"
            exit 1
            ;;
    esac
}

# ========================================
# 检测是否安装
# ========================================
is_installed() {
    command -v deepseek &>/dev/null
}

# ========================================
# 安装
# ========================================
install_app() {

    install_deps
    detect_arch

    if is_installed; then
        echo -e "${YELLOW}DeepSeek 已安装${RESET}"
        deepseek --version
        return
    fi

    echo -e "${GREEN}正在下载 DeepSeek...${RESET}"

    cd /tmp || exit

    curl -fsSL -o deepseek \
        "https://github.com/Hmbown/deepseek-tui/releases/latest/download/deepseek-linux-${ARCH}"

    if [[ ! -f deepseek ]]; then
        echo -e "${RED}下载失败${RESET}"
        return
    fi

    chmod +x deepseek

    echo -e "${GREEN}正在下载 SHA256 文件...${RESET}"

    curl -fsSL -O \
        https://github.com/Hmbown/deepseek-tui/releases/latest/download/deepseek-artifacts-sha256.txt

    echo -e "${GREEN}开始校验 SHA256...${RESET}"

    sha256sum -c deepseek-artifacts-sha256.txt --ignore-missing

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}SHA256 校验失败${RESET}"
        rm -f deepseek
        return
    fi

    mv deepseek /usr/local/bin/

    echo -e "${GREEN}安装完成${RESET}"

    deepseek --version
}

# ========================================
# 卸载
# ========================================
uninstall_app() {

    if ! is_installed; then
        echo -e "${YELLOW}DeepSeek 未安装${RESET}"
        return
    fi

    echo -e "${RED}正在卸载 DeepSeek...${RESET}"

    rm -f /usr/local/bin/deepseek

    echo -e "${GREEN}卸载完成${RESET}"
}

# ========================================
# 更新
# ========================================
update_app() {

    echo -e "${GREEN}正在更新 DeepSeek...${RESET}"

    deepseek update
}

# ========================================
# 启动
# ========================================
start_app() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek${RESET}"
        return
    fi

    deepseek
}

# ========================================
# 配置 API
# ========================================
set_auth() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek${RESET}"
        return
    fi

    deepseek auth set --provider deepseek
}

# ========================================
# Doctor
# ========================================
doctor_app() {

    if ! is_installed; then
        echo -e "${RED}请先安装 DeepSeek${RESET}"
        return
    fi

    deepseek doctor
}

# ========================================
# 查看版本
# ========================================
show_version() {

    if is_installed; then
        deepseek --version
    else
        echo -e "${YELLOW}未安装${RESET}"
    fi
}

# ========================================
# 菜单
# ========================================
menu() {

    clear

    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}      DeepSeek-TUI 管理菜单${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}1. 安装 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}2. 卸载 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}3. 更新 DeepSeek-TUI${RESET}"
    echo -e "${GREEN}4. 启动 DeepSeek TUI${RESET}"
    echo -e "${GREEN}5. 配置 API Key${RESET}"
    echo -e "${GREEN}6. Doctor 检查${RESET}"
    echo -e "${GREEN}7. 查看版本${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    echo -ne "${GREEN}请输入选项: ${RESET}"
    read CHOICE

    case "$CHOICE" in
        1)
            install_app
            ;;
        2)
            uninstall_app
            ;;
        3)
            update_app
            ;;
        4)
            start_app
            ;;
        5)
            set_auth
            ;;
        6)
            doctor_app
            ;;
        7)
            show_version
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            ;;
    esac

    echo
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# ========================================
# 主程序
# ========================================
check_root

while true; do
    menu
done
