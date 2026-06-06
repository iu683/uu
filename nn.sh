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

# 2. 强力清理残留的各种错误 APT 源（修复 404 导致 apt 报错的问题）
echo -e "${YELLOW}🧹 正在强力清理残留的官方故障软件源...${RESET}"
rm -f /etc/apt/sources.list.d/speedtest.list
rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
# 顺便清理可能写在 main sources.list 或其他地方的 packagecloud 记录
if [ -d /etc/apt/sources.list.d ]; then
    grep -l "packagecloud.io/ookla" /etc/apt/sources.list.d/* 2>/dev/null | xargs rm -f || true
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
    # 强制清理坏掉的缓存并更新
    apt-get clean
    apt-get update -y && apt-get install -y curl tar
fi

# 5. 下载官方原生程序 (引入 UA 伪装，绕过 Cloudflare/防火墙 403 限制)
echo -e "${YELLOW}📥 正在从 Ookla 官网下载 ${URL_ARCH} 版本...${RESET}"

cd /tmp
rm -f speedtest.tgz speedtest

# 添加 -A (User-Agent) 模拟 Chrome 浏览器，绕过 403 封锁
UA_TEXT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

if ! curl -L -f -A "$UA_TEXT" --connect-timeout 10 --retry 3 -o speedtest.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-${URL_ARCH}-linux.tgz"; then
    echo -e "${RED}❌ 下载失败！服务器拒绝了请求(403)或网络超时。${RESET}"
    exit 1
fi

# 6. 解压与权限配置
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
