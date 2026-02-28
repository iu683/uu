#!/bin/bash
# ==========================================
# CFServer 一键部署 + 重置令牌 + 重启服务
# ==========================================

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
yellow(){ echo -e "${YELLOW}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }

echo "========================================"
green "   CFServer 一键部署脚本"
echo "========================================"

# 获取公网IP
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

# 1️⃣ 下载并执行官方安装脚本
green "正在下载并执行部署脚本..."
curl -sS -O https://raw.githubusercontent.com/woniu336/open_shell/main/cfserver.sh
chmod +x cfserver.sh
./cfserver.sh

# 2️⃣ 重置令牌
yellow "是否现在重置访问令牌？(y/n)"
read -p "请选择: " choice

if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    cd /opt/cfserver || { red "目录不存在！"; exit 1; }
    ./dns-server -reset-token
fi

# 3️⃣ 重启服务
green "正在重启服务..."
cd /opt/cfserver || { red "目录不存在！"; exit 1; }

pkill dns-server 2>/dev/null
nohup ./dns-server > /dev/null 2>&1 &

sleep 2

green "服务已启动！"

echo ""
green "🌐 Web 管理地址："
echo ""
echo "   http://${IP}:8081"
echo ""
echo "========================================"
