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

# 2. 强力清理残留的各种官方故障/旧版 APT 源（彻底解决 Ubuntu 24.04 因为 noble 无源导致的 apt 报错）
echo -e "${YELLOW}🧹 正在强力清理残留的官方故障软件源...${RESET}"
rm -f /etc/apt/sources.list.d/speedtest.list
rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
if [ -d /etc/apt/sources.list.d ]; then
    grep -l "packagecloud.io/ookla" /etc/apt/sources.list.d/* 2>/dev/null | xargs rm -f || true
fi

# 3. 自动判断系统架构，并匹配官方准确的下载 URL (纠正了架构与 linux 字段颠倒的 Bug)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        DOWNLOAD_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-x86_64-linux.tgz"
        ;;
    aarch64)
        DOWNLOAD_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-aarch64-linux.tgz"
        ;;
    armhf|armv7l)
        DOWNLOAD_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-armhf-linux.tgz"
        ;;
    i386|i686)
        DOWNLOAD_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-i386-linux.tgz"
        ;;
    *)
        echo -e "${RED}❌ 暂不支持的架构: $ARCH${RESET}"
        exit 1
        ;;
esac

# 4. 检查并安装基础依赖
echo -e "${YELLOW}📦 正在检查并安装必要依赖 (curl/tar)...${RESET}"
if [ -f /etc/alpine-release ]; then
    # Alpine 额外补上 ca-certificates 防止明文/证书链报错
    apk add --no-cache curl tar ca-certificates
else
    # Debian/Ubuntu 强制清理可能坏掉的缓存并更新
    apt-get clean
    apt-get update -y && apt-get install -y curl tar
fi

# 5. 下载官方原生程序 (引入 UA 伪装，绕过 Cloudflare 防火墙 403 拦截)
echo -e "${YELLOW}📥 正在从 Ookla 官网下载原生二进制程序...${RESET}"

cd /tmp
# 提前清理历史坏文件残留，防止脏数据影响解压
rm -f speedtest.tgz speedtest

# 模拟 Chrome 浏览器 User-Agent，规避机房 IP 被 403 封锁
UA_TEXT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

if ! curl -L -f -A "$UA_TEXT" --connect-timeout 10 --retry 3 -o speedtest.tgz "$DOWNLOAD_URL"; then
    echo -e "${RED}❌ 下载失败！服务器拒绝了请求(403)或网络超时。${RESET}"
    exit 1
fi

# 6. 解压与环境变量配置
echo -e "${YELLOW}⚙️ 正在解压并配置环境变量...${RESET}"
tar -zxf speedtest.tgz speedtest
chmod +x speedtest
mv speedtest /usr/local/bin/
rm -f speedtest.tgz

# 刷新指令哈希缓存
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
