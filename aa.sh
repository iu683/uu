#!/usr/bin/env bash
set -e

# =========================================
# 91 面板一键安装脚本
# 支持自定义前台端口
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

# ================= 检查 root =================
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 或 sudo 运行"
    exit 1
fi

# ================= 检查依赖 =================
info "安装依赖..."
if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates
else
    err "不支持的系统包管理器"
    exit 1
fi
ok "依赖安装完成"

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

# ================= 输入端口 =================
DEFAULT_PORT=9191

read -rp "请输入前台端口 [默认 ${DEFAULT_PORT}]: " FRONTEND_PORT
FRONTEND_PORT=${FRONTEND_PORT:-$DEFAULT_PORT}

# 检查端口是否合法
if ! [[ "$FRONTEND_PORT" =~ ^[0-9]+$ ]] || \
   (( FRONTEND_PORT < 1 || FRONTEND_PORT > 65535 )); then
    err "端口无效"
    exit 1
fi

# 检查端口占用
if ss -tulnp 2>/dev/null | grep -q ":${FRONTEND_PORT} "; then
    warn "端口 ${FRONTEND_PORT} 已被占用"
    read -rp "是否继续安装？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

# ================= 下载官方脚本 =================
info "下载安装脚本..."
curl -fsSL https://raw.githubusercontent.com/nianzhibai/91/main/install.sh -o /tmp/install_91.sh

# ================= 开始安装 =================
info "开始安装 91 面板..."
FRONTEND_PORT=$FRONTEND_PORT bash /tmp/install_91.sh

# ================= 获取IP =================

SERVER_IP=$(get_public_ip)

ok "安装完成！"

echo
echo -e "${GREEN}访问地址:${RESET}"
echo -e "${YELLOW}前台: http://${SERVER_IP}:${FRONTEND_PORT}/${RESET}"
echo -e "${YELLOW}后台: http://${SERVER_IP}:${FRONTEND_PORT}/admin${RESET}"
echo -e "${YELLOW}快捷指令: 91${RESET}"

echo
warn "若无法访问，可尝试执行：91 restart"
