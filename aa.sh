#!/bin/bash

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s)
fi

# 根据系统执行对应的 Emby 反代脚本
case "$OS" in
    "alpine")
        echo "检测到 Alpine Linux，正在启动 Alpine 专用脚本..."
        bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/EmbyAlpine.sh)
        ;;
    *)
        echo "检测到系统为 $OS，正在启动通用版脚本..."
        bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/tool/main/Emby.sh)
        ;;
esac
