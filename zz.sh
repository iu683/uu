#!/bin/sh
# =========================================
# Alpine Linux 一键切换英文脚本
# =========================================

GREEN="\033[32m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }

# -------------------------
# 安装英文语言包
# -------------------------
info "安装英文语言包..."
apk update
apk add --no-cache musl-locales musl-locales-lang ttf-dejavu fontconfig

# -------------------------
# 配置系统语言环境
# -------------------------
info "配置系统语言环境为 English (en_US.UTF-8)..."

PROFILE="/etc/profile"

# 删除旧的中文环境变量（如果存在）
sed -i '/zh_CN/d' "$PROFILE"
sed -i '/LC_ALL=/d' "$PROFILE"
sed -i '/LANG=/d' "$PROFILE"
sed -i '/LANGUAGE=/d' "$PROFILE"

# 写入英文环境
cat << 'EOF' >> "$PROFILE"

export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
EOF

# 立即生效
. /etc/profile

# -------------------------
# 显示结果
# -------------------------
info "当前系统语言设置:"
locale

info "Test English output:"
echo "Hello, Alpine Linux!"

echo "[DONE] Alpine 已切换为英文环境，重新登录终端即可完全生效。"
