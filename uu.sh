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
    
    # 1. 强力清理残留的各种官方故障/旧版 APT 源（防止 noble 无源导致 apt 锁死）
    echo -e "${YELLOW}🧹 正在清理可能残留的故障软件源配置...${RESET}"
    rm -f /etc/apt/sources.list.d/speedtest.list
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
    if [ -d /etc/apt/sources.list.d ]; then
        grep -l "packagecloud.io/ookla" /etc/apt/sources.list.d/* 2>/dev/null | xargs rm -f || true
    fi

    # 2. 安装基础依赖 curl
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}📦 安装 curl...${RESET}"
        apt-get update -y && apt-get install -y curl
    fi

    # 3. 添加 Ookla 仓库（针对 Ubuntu 24.04 进行智能降级伪装）
    echo -e "${YELLOW}📦 正在配置 Ookla 官方原生 APT 仓库...${RESET}"
    
    # 获取当前系统代号
    CODENAME=$(lsb_release -c 2>/dev/null | awk '{print $2}' || grep "VERSION_CODENAME=" /etc/os-release | cut -d= -f2 || echo "unknown")

    if [ "$CODENAME" = "noble" ]; then
        # 抓取官方脚本，通过 sed 强制将 noble 替换为稳定有源的 jammy
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | \
        sed 's/os="${dist}"/os="ubuntu"/' | \
        sed 's/dist="${dist}"/dist="jammy"/' | bash
    else
        # 其他系统（如 Ubuntu 22.04、Debian 等）直接走官方标准脚本
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    fi

    # 4. 完美安装官方包
    echo -e "${YELLOW}📦 正在通过 APT 安装官方原生 Speedtest...${RESET}"
    apt-get update -y && apt-get install -y speedtest
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
