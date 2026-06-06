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
    echo -e "${YELLOW}📦 检测到 Debian/Ubuntu 系统，正在配置官方 APT 源...${RESET}"
    
    # 1. 安装基础依赖
    apt-get update -y
    apt-get install -y curl gpg gnupg apt-transport-https ca-certificates

    # 2. 导入 Ookla 官方 GPG 密钥与源 (2026最新标准流程)
    echo "🔑 正在导入 Ookla 官方密钥..."
    curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey | gpg --dearmor -o /etc/apt/keyrings/ookla-speedtest-cli-archive-keyring.gpg --yes

    echo "✍️ 正在添加 APT 软件源..."
    # 自动获取系统代号（如 focal, jammy, noble 等）
    DEB_DISTRO=$(lsb_release -sc 2>/dev/null || cat /etc/os-release | grep CODENAME | cut -d= -f2 | tr -d '"')
    # 如果获取失败，保底使用 debian
    if [ -z "$DEB_DISTRO" ]; then DEB_DISTRO="debian"; fi

    echo "deb [signed-by=/etc/apt/keyrings/ookla-speedtest-cli-archive-keyring.gpg] https://packagecloud.io/ookla/speedtest-cli/any/ any main" > /etc/apt/sources.list.d/speedtest.list

    # 3. 更新源并安装
    echo "📥 正在安装 speedtest..."
    apt-get update -y
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
