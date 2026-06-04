#!/bin/bash
# ======================================
# Ookla Speedtest 一键安装脚本
# Debian / Ubuntu / Alpine 全通用版
# ======================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}🚀 开始安装 Speedtest CLI...${RESET}"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 或 sudo 运行！${RESET}"
  exit 1
fi

# ======================================
# 智能分流安装引擎
# ======================================
if [ -f /etc/alpine-release ]; then
    # ---------------- Alpine Linux 部署分支 ----------------
    echo -e "${YELLOW}📦 检测到 Alpine 系统，正在下载官方静态二进制包...${RESET}"
    
    # 1. 安装必要的轻量基础依赖
    apk add --no-cache wget tar ca-certificates >/dev/null 2>&1
    
    # 2. 自动识别 CPU 架构 (x86_64 / arm64 等)
    arch=$(uname -m)
    download_arch="x86_64"
    
    case "$arch" in
        x86_64)   download_arch="x86_64" ;;
        aarch64|arm64) download_arch="aarch64" ;;
        armv7l)   download_arch="armhf" ;;
        i386|i686) download_arch="i386" ;;
        *) echo -e "${RED}❌ 抱歉，当前架构 $arch 暂无官方编译包${RESET}"; exit 1 ;;
    esac

    # 3. 下载 Ookla 官方 Linux 纯静态通用版
    url="https://download.speedtest.net/awt/cli/ookla-speedtest-1.2.0-linux-${download_arch}.tgz"
    
    wget -qO /tmp/speedtest.tgz "$url"
    
    # 4. 解压并移入系统全局路径
    tar -xzf /tmp/speedtest.tgz -C /tmp/ speedtest
    mv /tmp/speedtest /usr/local/bin/
    rm -f /tmp/speedtest.tgz
    chmod +x /usr/local/bin/speedtest

else
    # ---------------- Debian / Ubuntu 部署分支 ----------------
    # 1. 安装 curl
    if ! command -v curl >/dev/null 2>&1; then
      echo "📦 安装 curl..."
      apt-get update -y
      apt-get install -y curl
    fi

    # 2. 添加 Ookla 官方源
    echo "📦 添加 Ookla 仓库..."
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash

    # 3. 安装 speedtest
    echo "📦 安装 speedtest..."
    apt-get install -y speedtest
fi

# 确保命令哈希表刷新，防止找不到命令
hash -r 2>/dev/null

echo -e "${GREEN}✅ 安装完成！${RESET}"

# ======================================
# 自动测速
# ======================================
echo ""
echo -e "${GREEN}🚀 开始测速...${RESET}"
echo "-------------------------------------"

# 运行测速并自动同意 Ookla 的用户隐私协议
speedtest --accept-license --accept-gdpr

echo "-------------------------------------"
echo -e "${GREEN}🎉 完成！以后直接运行： speedtest${RESET}"
