#!/bin/bash
# ======================================
# Ookla / Open-Source Speedtest 一键安装脚本
# Debian / Ubuntu / Alpine 全系统完美适配版
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
    echo -e "${YELLOW}📦 检测到 Alpine 系统，正在通过 apk 官方源安装...${RESET}"
    
    # 1. 直接一行命令安装官方源的 speedtest-cli
    apk add --no-cache speedtest-cli
    
    # 2. 创建软链接，确保全局命令与商业版 speedtest 兼容，防止后续脚本卡死
    if [ ! -f /usr/local/bin/speedtest ] && [ ! -f /usr/bin/speedtest ]; then
        ln -sf $(command -v speedtest-cli) /usr/bin/speedtest
    fi

else
    # ---------------- Debian / Ubuntu 部署分支 ----------------
    # 1. 安装 curl
    if ! command -v curl >/dev/null 2>&1; then
      echo "📦 安装 curl..."
      apt-get update -y
      apt-get install -y curl
    fi

    # 2. 添加 Ookla 官方源并安装
    echo "📦 添加 Ookla 仓库并安装..."
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt-get install -y speedtest
fi

# 确保命令哈希表刷新
hash -r 2>/dev/null

echo -e "${GREEN}✅ 安装完成！${RESET}"

# ======================================
# 自动测速
# ======================================
echo ""
echo -e "${GREEN}🚀 开始测速...${RESET}"
echo "-------------------------------------"

# 智能判断：开源版 speedtest-cli 不需要也不支持这两个商业隐私参数
if speedtest --help 2>&1 | grep -q "accept-license"; then
    speedtest --accept-license --accept-gdpr
else
    speedtest
fi

echo "-------------------------------------"
echo -e "${GREEN}🎉 完成！以后直接运行： speedtest${RESET}"
