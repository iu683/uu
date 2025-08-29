#!/bin/sh
# =========================================
# Alpine Linux 一键切换中文脚本
# =========================================

GREEN="\033[32m"
RESET="\033[0m"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }

# -------------------------
# 安装中文语言包
# -------------------------
info "安装中文语言包..."
apk update
apk add --no-cache musl-locales musl-locales-lang ttf-dejavu fontconfig

# -------------------------
# 配置系统语言环境
# -------------------------
info "配置系统语言环境..."
PROFILE="/etc/profile"

# 避免重复添加
grep -q "zh_CN.UTF-8" "$PROFILE" || cat << 'EOF' >> "$PROFILE"

export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
EOF

# 立即生效
. /etc/profile

# -------------------------
# 显示设置结果
# -------------------------
info "当前系统语言设置:"
locale

info "测试中文显示:"
echo "你好，Alpine!"

echo "[DONE] Alpine 已切换为中文环境。重启终端或系统可完全生效。"
