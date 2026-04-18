#!/bin/bash
# ========================================
# Cloudflare Tunnel (cloudflared) 彻底卸载脚本
# 支持：systemd / docker / 手动安装 / 隧道配置 / 证书 / 进程
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}   Cloudflare Tunnel 彻底卸载${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止 systemd 服务
# =============================
echo -e "${YELLOW}[1/6] 停止 systemd 服务...${RESET}"

systemctl stop cloudflared 2>/dev/null
systemctl disable cloudflared 2>/dev/null

systemctl stop cloudflared@* 2>/dev/null
systemctl disable cloudflared@* 2>/dev/null

rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/cloudflared@*.service
systemctl daemon-reload 2>/dev/null

# =============================
# 2. 杀掉进程
# =============================
echo -e "${YELLOW}[2/6] 清理运行进程...${RESET}"

pkill -f cloudflared 2>/dev/null

# =============================
# 3. 删除二进制
# =============================
echo -e "${YELLOW}[3/6] 删除程序文件...${RESET}"

rm -f /usr/bin/cloudflared
rm -f /usr/local/bin/cloudflared
rm -f /bin/cloudflared

# =============================
# 4. 删除配置 / 证书 / 隧道数据
# =============================
echo -e "${YELLOW}[4/6] 清理配置与隧道数据...${RESET}"

rm -rf /etc/cloudflared
rm -rf /opt/cloudflared
rm -rf /var/lib/cloudflared
rm -rf ~/.cloudflared

# 常见隧道凭证
rm -f ~/.cloudflared/*.json
rm -f /etc/cloudflared/*.json
rm -f /etc/cloudflared/*.yml
rm -f /etc/cloudflared/*.yaml

# tunnel token / cert
rm -f ~/.cloudflared/cert.pem
rm -f ~/.cloudflared/credentials.json

# =============================
# 5. 清理环境变量
# =============================
echo -e "${YELLOW}[5/6] 清理环境变量...${RESET}"

sed -i '/cloudflared/d' ~/.bashrc 2>/dev/null
sed -i '/cloudflared/d' ~/.profile 2>/dev/null
sed -i '/cloudflared/d' /etc/profile 2>/dev/null

# =============================
# 6. Docker 清理（重点）
# =============================
echo -e "${YELLOW}[6/6] 清理 Docker Cloudflare Tunnel...${RESET}"

if command -v docker &>/dev/null; then

    echo -e "${YELLOW}检查 cloudflared 容器...${RESET}"
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "cloudflared|tunnel" | awk '{print $1}' | xargs -r docker stop 2>/dev/null
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "cloudflared|tunnel" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null

    echo -e "${YELLOW}检查 cloudflared 镜像...${RESET}"
    docker images --format '{{.Repository}} {{.ID}}' | grep -Ei "cloudflared|cloudflare" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null

    echo -e "${YELLOW}检查 tunnel volume...${RESET}"
    docker volume ls --format '{{.Name}}' | grep -Ei "cloudflared|tunnel" | xargs -r docker volume rm 2>/dev/null

    echo -e "${GREEN}Docker tunnel 清理完成${RESET}"

else
    echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
fi

# =============================
# 最终检测
# =============================
echo -e "${YELLOW}检查残留状态...${RESET}"

cf_proc=$(ps -ef | grep -Ei "cloudflared" | grep -v grep)

if [[ -n "$cf_proc" ]]; then
    echo -e "${RED}仍有进程残留:${RESET}"
    echo "$cf_proc"
else
    echo -e "${GREEN}无 cloudflared 进程残留${RESET}"
fi

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}   Cloudflare Tunnel 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
