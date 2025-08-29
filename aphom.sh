#!/bin/sh
# =========================================
# Alpine Linux 一键修改主机名脚本（交互式）
# =========================================

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }
error() { echo -e "${RED}[ERROR] $1${RESET}"; }

# -------------------------
# 读取新主机名
# -------------------------
read -r -p "请输入新的主机名: " NEW_HOSTNAME

if [ -z "$NEW_HOSTNAME" ]; then
    error "主机名不能为空！"
    exit 1
fi

# -------------------------
# 临时修改
# -------------------------
info "临时修改主机名为: $NEW_HOSTNAME"
hostname "$NEW_HOSTNAME"

# -------------------------
# 永久修改 /etc/hostname
# -------------------------
info "永久修改 /etc/hostname"
echo "$NEW_HOSTNAME" > /etc/hostname

# -------------------------
# 更新 /etc/hosts
# -------------------------
info "更新 /etc/hosts"
if grep -q "127.0.0.1" /etc/hosts; then
    # 替换已有行
    sed -i "s/^127\.0\.0\.1.*/127.0.0.1   $NEW_HOSTNAME localhost/" /etc/hosts
else
    # 添加新行
    echo "127.0.0.1   $NEW_HOSTNAME localhost" >> /etc/hosts
fi

# -------------------------
# 重启 hostname 服务立即生效
# -------------------------
if [ -x /etc/init.d/hostname ]; then
    /etc/init.d/hostname restart
fi

info "✅ 主机名已修改为: $NEW_HOSTNAME"
