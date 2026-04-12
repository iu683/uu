#!/bin/bash
# ============================================
# 1Panel 本地应用更新脚本（安全备份 + 自动重启）
# ============================================

# ==============================
# 检查并安装 unzip
# ==============================
check_unzip() {
    if ! command -v unzip >/dev/null 2>&1; then
        echo "⚠️ 未检测到 unzip，正在安装..."

        if [ -f /etc/debian_version ]; then
            apt update && apt install -y unzip
        elif [ -f /etc/redhat-release ]; then
            yum install -y unzip || dnf install -y unzip
        elif [ -f /etc/alpine-release ]; then
            apk add unzip
        else
            echo "❌ 无法识别系统，请手动安装 unzip"
            exit 1
        fi

        echo "✅ unzip 安装完成"
    fi
}

check_unzip

# ==============================
# 基本变量
# ==============================
LOCAL_PATH="/opt/1panel/resource/apps/local"
ZIP_URL="https://github.com/okxlin/appstore/archive/refs/heads/localApps.zip"
BACKUP_DIR="/opt/1panel/resource/apps/backup_$(date +%Y%m%d_%H%M%S)"

# ==============================
# 检查目录
# ==============================
if [ ! -d "$LOCAL_PATH" ]; then
    echo "❌ 未检测到 1Panel 本地应用目录：$LOCAL_PATH"
    echo "请确认 1Panel 是否已安装。"
    exit 1
fi

# ==============================
# 创建备份
# ==============================
echo "📦 正在备份本地应用到：$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cp -rf "$LOCAL_PATH"/* "$BACKUP_DIR"/

# ==============================
# 下载新版本
# ==============================
echo "⬇️ 正在下载最新 localApps.zip ..."

if ! wget -O "$LOCAL_PATH/localApps.zip" "$ZIP_URL"; then
    echo "❌ 下载失败，已终止更新"
    exit 1
fi

# ==============================
# 解压前校验
# ==============================
if [ ! -f "$LOCAL_PATH/localApps.zip" ]; then
    echo "❌ 未找到下载文件"
    exit 1
fi

echo "📂 正在解压覆盖文件..."
unzip -o -d "$LOCAL_PATH" "$LOCAL_PATH/localApps.zip"

# ==============================
# 覆盖 apps
# ==============================
cp -rf "$LOCAL_PATH/appstore-localApps/apps/"* "$LOCAL_PATH/"

# ==============================
# 清理
# ==============================
rm -rf "$LOCAL_PATH/appstore-localApps" "$LOCAL_PATH/localApps.zip"

# ==============================
# 重启 1Panel
# ==============================
echo "🔄 正在重启 1Panel..."
if command -v 1pctl >/dev/null 2>&1; then
    1pctl restart
    echo "✅ 1Panel 已成功重启"
else
    echo "⚠️ 未检测到 1pctl 命令，请确认 1Panel 是否正确安装"
    echo "你可以手动执行：1pctl restart"
fi

echo "✅ 本地应用更新完成！"
echo "🗂 已备份旧版本到：$BACKUP_DIR"
