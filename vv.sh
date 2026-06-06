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
    echo -e "${YELLOW}📦 检测到 Debian/Ubuntu 系统，正在通过二进制包快速安装...${RESET}"
    
    # 1. 确保有 wget 或 curl 以及 tar
    if ! command -v tar >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y tar wget
    elif ! command -v wget >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y wget
    fi

    # 2. 架构检测并匹配下载链接
    cpu_arch=$(uname -m)
    download_url=""
    
    case "$cpu_arch" in
        x86_64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
            ;;
        aarch64)
            download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
            ;;
        *)
            echo -e "${RED}❌ 错误: 不支持的架构 ${cpu_arch}${RESET}" >&2
            exit 1
            ;;
    esac
    
    # 3. 下载并解压到系统目录
    cd /tmp
    wget -q "$download_url" -O speedtest.tgz && \
    tar -xzf speedtest.tgz && \
    mv speedtest /usr/local/bin/ && \
    rm -f speedtest.tgz speedtest.5 speedtest.md LICENSE.md # 清理垃圾
fi

# 确保命令哈希表刷新
hash -r 2>/dev/null

echo -e "${GREEN}✅ 安装完成！${RESET}"

# ======================================
# 自动测速（双保险免提示版）
# ======================================
echo ""
echo -e "${GREEN}🚀 开始测速...${RESET}"
echo "-------------------------------------"

# 1. 提前为 Ookla 商业版注入免输入配置（即使参数失效，配置文件也会强制跳过提示）
if [ -d "$HOME/.ookla" ]; then
    echo "yes" > "$HOME/.ookla/speedtest-cli.json" 2>/dev/null || true
fi

# 2. 智能判断并执行测速
if speedtest --help 2>&1 | grep -q "accept-license"; then
    # 塞入 YES 应对某些严格版本，并带上官方免提示参数
    echo "YES" | speedtest --accept-license --accept-gdpr --force || true
else
    speedtest
fi

echo "-------------------------------------"
