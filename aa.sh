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
# 检查并安装依赖（兼容包管理器）
# ================================
install_if_missing() {
    local pkg=$1
    if type "$pkg" &>/dev/null; then
        info "$pkg 已安装"
    else
        warn "$pkg 未安装，正在安装..."
        if type apt &>/dev/null; then
            apt update && apt install -y "$pkg"
        elif type apk &>/dev/null; then
            apk add --no-cache "$pkg"
        else
            error "不支持的系统包管理器，请手动安装 $pkg"
            exit 1
        fi
    fi
}

install_if_missing wget
install_if_missing curl
install_if_missing ca-certificates

# ================================
# 下载 aria2 脚本
# ================================
# 显式指定落地的绝对路径，防止进程目录漂移
ARIA2_SCRIPT="/tmp/aria2.sh"

# 如果你希望每次都用最新的，可以去掉 if 判断，直接 wget 覆盖
if [[ ! -f $ARIA2_SCRIPT ]]; then
    info "正在部署aria2..."
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
