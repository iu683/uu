#!/bin/bash
# ======================================
# Ookla Speedtest 官方二进制免源通用脚本
# 完美适配 Ubuntu 24.04 / Debian / Alpine
# ======================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}🚀 开始安装 Speedtest CLI (二进制独立版)...${RESET}"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 或 sudo 运行！${RESET}"
  exit 1
fi

# 清理之前残留的错误 APT 源，防止后续 apt 报错
if [ -f /etc/apt/sources.list.d/speedtest.list ]; then
    rm -f /etc/apt/sources.list.d/speedtest.list
    echo -e "${YELLOW}🧹 已清理残留的错误软件源配置。${RESET}"
fi

# 1. 自动判断系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  URL_ARCH="x86_64" ;;
    aarch64) URL_ARCH="aarch64" ;;
    armhf|armv7l) URL_ARCH="armhf" ;;
    i386|i686)   URL_ARCH="i386" ;;
    *) echo -e "${RED}❌ 暂不支持的架构: $ARCH${RESET}"; exit 1 ;;
esac

# 2. 下载并安装
echo -e "${YELLOW}📦 正在从 Ookla 官网下载 ${URL_ARCH} 版本的原生程序...${RESET}"

# 确保有 curl 或 wget 还有 tar
if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl tar
else
    apt-get update -y && apt-get install -y curl tar
fi

# 下载官方编译好的静态二进制包
cd /tmp
curl -L -o speedtest.tgz "https://bintray.com/ookla/download/speedtest-cli/ookla-speedtest-1.2.0-${URL_ARCH}-linux.tgz" 2>/dev/null || \
curl -L -o speedtest.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-${URL_ARCH}-linux.tgz"

# 解压并移到系统目录
tar -zxf speedtest.tgz speedtest
mv speedtest /usr/local/bin/
rm -f speedtest.tgz

# 刷新指令哈希
hash -r 2>/dev/null
echo -e "${GREEN}✅ 官方原生 Speedtest 安装成功！${RESET}"

# ======================================
# 自动测速
# ======================================
echo ""
echo -e "${GREEN}🚀 开始测速...${RESET}"
echo "-------------------------------------"

# 运行测速并自动同意隐私协议
speedtest --accept-license --accept-gdpr

echo "-------------------------------------"
echo -e "${GREEN}🎉 完成！以后在任意地方输入 speedtest 即可测速。${RESET}"
