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

# 1. 必须 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 或 sudo 运行！${RESET}"
    exit 1
fi

# 2. 清理之前可能残留的错误 APT 源
if [ -f /etc/apt/sources.list.d/speedtest.list ]; then
    rm -f /etc/apt/sources.list.d/speedtest.list
    echo -e "${YELLOW}🧹 已清理残留的错误软件源配置。${RESET}"
fi

# 3. 自动判断系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)       URL_ARCH="x86_64" ;;
    aarch64)      URL_ARCH="aarch64" ;;
    armhf|armv7l) URL_ARCH="armhf" ;;
    i386|i686)    URL_ARCH="i386" ;;
    *) echo -e "${RED}❌ 暂不支持的架构: $ARCH${RESET}"; exit 1 ;;
esac

# 4. 检查并安装基础依赖
echo -e "${YELLOW}📦 正在检查并安装必要依赖 (curl/tar)...${RESET}"
if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl tar ca-certificates
else
    apt-get update -y && apt-get install -y curl tar
fi

# 5. 下载官方原生程序 (修复了 404 伪成功和死链问题)
echo -e "${YELLOW}📥 正在从 Ookla 官网下载 ${URL_ARCH} 版本...${RESET}"

cd /tmp
# 强制清理可能存在的历史坏文件
rm -f speedtest.tgz speedtest

# -f 参数确保 404 时直接报错跳出，--retry 确保网络抖动时可重试
if ! curl -L -f --connect-timeout 10 --retry 3 -o speedtest.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-${URL_ARCH}-linux.tgz"; then
    echo -e "${RED}❌ 下载失败，请检查网络是否能访问 install.speedtest.net${RESET}"
    exit 1
fi

# 6. 解压与权限修复
echo -e "${YELLOW}⚙️ 正在解压并配置环境变量...${RESET}"
tar -zxf speedtest.tgz speedtest
chmod +x speedtest
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
