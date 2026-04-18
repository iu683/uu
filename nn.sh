#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OpenCode"
BIN="opencode"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

info(){ echo -e "${GREEN}[信息] $1${RESET}"; }
warn(){ echo -e "${YELLOW}[警告] $1${RESET}"; }
err(){ echo -e "${RED}[错误] $1${RESET}"; }

pause(){ read -rp "按回车继续..." _; }

# ==============================
# 环境检测
# ==============================
check_env() {
    info "检查 Node.js 环境..."

    if ! command -v node >/dev/null 2>&1; then
        warn "未检测到 Node.js，自动安装中..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    if ! command -v npm >/dev/null 2>&1; then
        err "npm 不存在，安装失败"
        exit 1
    fi

    info "环境正常"
}

# ==============================
# 安装
# ==============================
install_opencode() {
    check_env
    info "安装 OpenCode..."

    npm install -g opencode-ai || {
        err "安装失败"
        return
    }

    info "安装完成"
}

# ==============================
# 登录
# ==============================
login_opencode() {
    if ! command -v opencode >/dev/null 2>&1; then
        err "请先安装 OpenCode"
        return
    fi

    info "开始登录 Provider..."
    opencode providers login
}
# ==============================
# 登录状态
# ==============================
status_opencode() {
    if ! command -v $BIN >/dev/null 2>&1; then
        warn "未安装"
        return
    fi

    info "当前 Provider 状态："

    if opencode providers list >/dev/null 2>&1; then
        opencode providers list
    else
        warn "未配置任何 Provider（未登录）"
    fi
}

# ==============================
# 版本
# ==============================
version_opencode() {
    echo -e "${CYAN}===== 版本信息 =====${RESET}"

    if command -v opencode >/dev/null 2>&1; then
        echo "OpenCode: $(opencode --version)"
    else
        echo "OpenCode: 未安装"
    fi

    echo "Node.js: $(node -v 2>/dev/null || echo 未安装)"
    echo "npm: $(npm -v 2>/dev/null || echo 未安装)"
}

# ==============================
# 交互模式
# ==============================
interactive_opencode() {
    if command -v opencode >/dev/null 2>&1; then
        info "进入交互模式（Ctrl+C 退出）"
        opencode
    else
        err "未安装 opencode"
    fi
}

# ==============================
# 更新
# ==============================
update_opencode() {
    info "更新 OpenCode..."
    npm update -g opencode-ai || warn "更新失败"
    info "完成"
}

# ==============================
# 卸载
# ==============================
uninstall_opencode() {
    warn "卸载 OpenCode..."

    npm uninstall -g opencode-ai || true
    rm -rf /root/.cache/opencode
    rm -rf /root/.config/opencode

    info "已卸载"
}

# ==============================
# 环境信息
# ==============================
env_info() {
    echo -e "${CYAN}===== 环境信息 =====${RESET}"
    echo "系统: $(uname -a)"
    echo "Node: $(node -v 2>/dev/null || echo 未安装)"
    echo "npm: $(npm -v 2>/dev/null || echo 未安装)"
    echo "OpenCode: $(opencode --version 2>/dev/null || echo 未安装)"
    echo "PATH: $PATH"
}

# ==============================
# 菜单
# ==============================
menu() {
    clear
    echo -e "${GREEN}==== $APP_NAME ==== ${RESET}"
    echo -e "${GREEN}1. 安装 OpenCode${RESET}"
    echo -e "${GREEN}2. 登录${RESET}"
    echo -e "${GREEN}3. 查看登录状态${RESET}"
    echo -e "${GREEN}4. 检查版本${RESET}"
    echo -e "${GREEN}5. 进入交互模式${RESET}"
    echo -e "${GREEN}6. 更新${RESET}"
    echo -e "${GREEN}7. 卸载${RESET}"
    echo -e "${GREEN}8. 环境信息${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    read -rp "请输入选项: " choice

    case $choice in
        1) install_opencode ;;
        2) login_opencode ;;
        3) status_opencode ;;
        4) version_opencode ;;
        5) interactive_opencode ;;
        6) update_opencode ;;
        7) uninstall_opencode ;;
        8) env_info ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    pause
    menu
}

menu
