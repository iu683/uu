#!/bin/bash
# ========================================
# GOST 彻底卸载脚本
# 支持：systemd / docker / 手动安装 / 进程 / 配置 / 端口残留
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}        GOST 彻底卸载${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止 systemd 服务
# =============================
echo -e "${YELLOW}[1/6] 停止 systemd 服务...${RESET}"

systemctl stop gost 2>/dev/null
systemctl disable gost 2>/dev/null

systemctl stop gost@* 2>/dev/null
systemctl disable gost@* 2>/dev/null

rm -f /etc/systemd/system/gost.service
rm -f /etc/systemd/system/gost@*.service
systemctl daemon-reload 2>/dev/null

# =============================
# 2. 杀掉进程
# =============================
echo -e "${YELLOW}[2/6] 清理运行进程...${RESET}"

pkill -f gost 2>/dev/null

# =============================
# 3. 删除二进制文件 & 配置
# =============================
echo -e "${YELLOW}[3/6] 删除程序文件...${RESET}"

rm -f /usr/bin/gost
rm -f /usr/local/bin/gost
rm -f /bin/gost

rm -rf /etc/gost
rm -rf /opt/gost
rm -rf /var/lib/gost
rm -rf ~/.gost

rm -f /etc/gost.json
rm -f /etc/gost.yaml
rm -f /etc/gost.yml

# =============================
# 4. 清理启动脚本 / 环境变量
# =============================
echo -e "${YELLOW}[4/6] 清理环境残留...${RESET}"

sed -i '/gost/d' ~/.bashrc 2>/dev/null
sed -i '/gost/d' ~/.profile 2>/dev/null
sed -i '/gost/d' /etc/profile 2>/dev/null

# =============================
# 5. Docker 清理（重点）
# =============================
echo -e "${YELLOW}[5/6] 清理 Docker GOST...${RESET}"

if command -v docker &>/dev/null; then

    echo -e "${YELLOW}检查 gost 容器...${RESET}"
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "gost" | awk '{print $1}' | xargs -r docker stop 2>/dev/null
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "gost" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null

    echo -e "${YELLOW}检查 gost 镜像...${RESET}"
    docker images --format '{{.Repository}} {{.ID}}' | grep -Ei "gost" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null

    echo -e "${YELLOW}检查 gost volume...${RESET}"
    docker volume ls --format '{{.Name}}' | grep -Ei "gost" | xargs -r docker volume rm 2>/dev/null

    echo -e "${GREEN}Docker gost 清理完成${RESET}"

else
    echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
fi

# =============================
# 6. 检查残留
# =============================
echo -e "${YELLOW}[6/6] 检查残留状态...${RESET}"

gost_proc=$(ps -ef | grep -Ei "gost" | grep -v grep)

if [[ -n "$gost_proc" ]]; then
    echo -e "${RED}仍有进程残留:${RESET}"
    echo "$gost_proc"
else
    echo -e "${GREEN}无进程残留${RESET}"
fi

# 检查端口占用（常见代理端口）
ss -lntp 2>/dev/null | grep -Ei "gost"

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}        GOST 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
