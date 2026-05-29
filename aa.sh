#!/usr/bin/env bash
set -e

# =========================================
# 小皮面板 XP 一键安装脚本
# =========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

info() { echo -e "${BLUE}[信息]${RESET} $1"; }
ok() { echo -e "${GREEN}[完成]${RESET} $1"; }
warn() { echo -e "${YELLOW}[提示]${RESET} $1"; }
err() { echo -e "${RED}[错误]${RESET} $1"; }

# ================= root 检查 =================
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 或 sudo 运行"
    exit 1
fi

# ================= 安装依赖 =================
info "安装依赖..."

if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y curl wget ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget ca-certificates
fi

ok "依赖安装完成"

# ================= 下载脚本 =================
info "下载安装小皮面板..."

if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
        https://dl.xp.cn/dl/xp/install.sh \
        -o /tmp/xp_install.sh
else
    wget -qO \
        /tmp/xp_install.sh \
        https://dl.xp.cn/dl/xp/install.sh
fi

chmod +x /tmp/xp_install.sh

# ================= 开始安装 =================
info "开始安装小皮面板..."

set +e
bash /tmp/xp_install.sh
INSTALL_EXIT=$?
set -e


echo
if [[ $INSTALL_EXIT -eq 0 ]]; then
    ok "安装脚本执行完成！"
else
    warn "安装脚本返回异常（退出码: $INSTALL_EXIT）"
fi
