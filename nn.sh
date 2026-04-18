#!/usr/bin/env bash
set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[信息] $1${RESET}"; }
warn()  { echo -e "${YELLOW}[警告] $1${RESET}"; }
error() { echo -e "${RED}[错误] $1${RESET}"; }

# ================================
# 检查 root
# ================================
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 运行该脚本"
    exit 1
fi

# ================================
# 检查并安装依赖
# ================================
install_if_missing() {
    local pkg=$1
    if dpkg -s "$pkg" &>/dev/null; then
    
    else
        warn "$pkg 未安装，正在安装..."
        apt install -y "$pkg"
    fi
}

install_if_missing wget
install_if_missing curl
install_if_missing ca-certificates

# ================================
# 下载 aria2 脚本
# ================================
ARIA2_SCRIPT="aria2.sh"

if [[ -f $ARIA2_SCRIPT ]]; then
    
    wget -q -O $ARIA2_SCRIPT https://git.io/aria2.sh || {
        error "下载失败，请检查网络"
        exit 1
    }
    chmod +x $ARIA2_SCRIPT
fi

# ================================
# 执行脚本
# ================================
bash $ARIA2_SCRIPT
