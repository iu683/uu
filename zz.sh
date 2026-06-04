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
    
    # 1. 安装必要的轻量基础依赖（允许失败，防止因软件源问题卡死）
    apk add --no-cache wget tar ca-certificates >/dev/null 2>&1 || true
    
    # 2. 自动识别 CPU 架构
    arch=$(uname -m)
    download_arch="x86_64"
    
    case "$arch" in
        x86_64)   download_arch="x86_64" ;;
        aarch64|arm64) download_arch="aarch64" ;;
        armv7l)   download_arch="armhf" ;;
        i386|i686) download_arch="i386" ;;
        *) echo -e "${RED}❌ 抱歉，当前架构 $arch 暂无官方编译包${RESET}"; exit 1 ;;
    esac

    # 3. 下载并解压（针对 Alpine BusyBox 优化的管道流，不生成临时文件，极稳）
    url="https://download.speedtest.net/awt/cli/ookla-speedtest-1.2.0-linux-${download_arch}.tgz"
    
    # 创建一个临时目录用于解压
    mkdir -p /tmp/spd_install
    
    # 使用 wget 下载，如果失败给出明确提示，而不是闷声闪退
    if ! wget -qO /tmp/spd_install/speedtest.tgz "$url"; then
        echo -e "${RED}❌ 下载 Speedtest 失败，请检查网络或 DNS 设置！${RESET}"
        exit 1
    fi
    
    # Alpine 的 tar 完美解压命令
    cd /tmp/spd_install
    tar -xzf speedtest.tgz speedtest
    
    # 移动到全局路径
    mv speedtest /usr/local/bin/
    chmod +x /usr/local/bin/speedtest
    
    # 清理现场
    cd - >/dev/null
    rm -rf /tmp/spd_install

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
