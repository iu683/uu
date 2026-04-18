#!/bin/bash
# ========================================
# Cloudflare Tunnel / Argo 彻底卸载脚本
# 支持：systemd / docker / 手动下载 (argo) / 进程
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}   Cloudflare / Argo Tunnel 彻底卸载${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止 systemd 服务
# =============================
echo -e "${YELLOW}[1/6] 停止 systemd 服务 (cloudflared/argo)...${RESET}"

# 同时尝试停止 cloudflared 和可能存在的 argo 服务
for service in cloudflared argo; do
    systemctl stop $service 2>/dev/null
    systemctl disable $service 2>/dev/null
    systemctl stop ${service}@* 2>/dev/null
    systemctl disable ${service}@* 2>/dev/null
    rm -f /etc/systemd/system/${service}.service
    rm -f /etc/systemd/system/${service}@*.service
done

systemctl daemon-reload 2>/dev/null

# =============================
# 2. 杀掉进程
# =============================
echo -e "${YELLOW}[2/6] 清理运行进程 (cloudflared/argo)...${RESET}"

# -f 匹配命令行，确保重命名为 argo 的进程也能被杀掉
pkill -f cloudflared 2>/dev/null
pkill -f argo 2>/dev/null

# =============================
# 3. 删除二进制 (增加 argo 路径)
# =============================
echo -e "${YELLOW}[3/6] 删除程序文件...${RESET}"

# 1. 删除标准路径
rm -f /usr/bin/cloudflared /usr/local/bin/cloudflared /bin/cloudflared
rm -f /usr/bin/argo /usr/local/bin/argo /bin/argo

# 2. 删除你脚本中 ${work_dir}/argo 习惯的本地文件
# 尝试匹配当前目录下或常见工作目录下的 argo
rm -f ./argo
if [[ -n "$work_dir" ]]; then
    rm -f "${work_dir}/argo"
fi

# =============================
# 4. 删除配置 / 证书 / 数据
# =============================
echo -e "${YELLOW}[4/6] 清理配置与隧道数据...${RESET}"

rm -rf /etc/cloudflared /opt/cloudflared /var/lib/cloudflared ~/.cloudflared
rm -rf /etc/argo /opt/argo ~/.argo

# =============================
# 5. 清理环境变量
# =============================
echo -e "${YELLOW}[5/6] 清理环境变量...${RESET}"

for file in ~/.bashrc ~/.profile /etc/profile; do
    sed -i '/cloudflared/d' $file 2>/dev/null
    sed -i '/argo/d' $file 2>/dev/null
done

# =============================
# 6. Docker 清理 (增加 argo 匹配)
# =============================
echo -e "${YELLOW}[6/6] 清理 Docker 中的 Tunnel...${RESET}"

if command -v docker &>/dev/null; then

    echo -e "${YELLOW}检查相关容器 (cloudflared/tunnel/argo)...${RESET}"
    # 模糊匹配包含 argo 的容器并清理
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "cloudflared|tunnel|argo" | awk '{print $1}' | xargs -r docker stop 2>/dev/null
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "cloudflared|tunnel|argo" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null

    echo -e "${YELLOW}检查相关镜像...${RESET}"
    docker images --format '{{.Repository}} {{.ID}}' | grep -Ei "cloudflared|cloudflare|argo" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null

    echo -e "${YELLOW}检查相关 volume...${RESET}"
    docker volume ls --format '{{.Name}}' | grep -Ei "cloudflared|tunnel|argo" | xargs -r docker volume rm 2>/dev/null

    echo -e "${GREEN}Docker 清理完成${RESET}"
else
    echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
fi

# =============================
# 最终检测
# =============================
echo -e "${YELLOW}检查残留状态...${RESET}"

# 综合检查所有关键字进程
residual_proc=$(ps -ef | grep -Ei "cloudflared|argo" | grep -v grep)

if [[ -n "$residual_proc" ]]; then
    echo -e "${RED}警告: 仍有进程残留:${RESET}"
    echo "$residual_proc"
else
    echo -e "${GREEN}恭喜: 无 cloudflared/argo 进程残留${RESET}"
fi

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}    Tunnel / Argo 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
