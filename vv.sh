#!/bin/bash
# ========================================
# FRP 彻底卸载脚本（frps / frpc）
# 支持：systemd / docker / 手动安装 / 配置 / 进程 / 端口
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}        FRP 彻底卸载${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止 systemd 服务
# =============================
echo -e "${YELLOW}[1/6] 停止 systemd 服务...${RESET}"

systemctl stop frps 2>/dev/null
systemctl stop frpc 2>/dev/null
systemctl disable frps 2>/dev/null
systemctl disable frpc 2>/dev/null

systemctl stop frps@* 2>/dev/null
systemctl stop frpc@* 2>/dev/null

rm -f /etc/systemd/system/frps.service
rm -f /etc/systemd/system/frpc.service
rm -f /etc/systemd/system/frps@*.service
rm -f /etc/systemd/system/frpc@*.service

systemctl daemon-reload 2>/dev/null

# =============================
# 2. 杀掉进程
# =============================
echo -e "${YELLOW}[2/6] 清理运行进程...${RESET}"

pkill -f frps 2>/dev/null
pkill -f frpc 2>/dev/null

# =============================
# 3. 删除二进制 & 配置
# =============================
echo -e "${YELLOW}[3/6] 删除程序文件...${RESET}"

rm -f /usr/bin/frps /usr/bin/frpc
rm -f /usr/local/bin/frps /usr/local/bin/frpc
rm -f /bin/frps /bin/frpc

rm -rf /etc/frp
rm -rf /opt/frp
rm -rf /var/lib/frp

rm -f /etc/frps.ini /etc/frpc.ini
rm -f /etc/frps.toml /etc/frpc.toml

rm -rf ~/.frp

# =============================
# 4. 清理环境残留
# =============================
echo -e "${YELLOW}[4/6] 清理环境变量...${RESET}"

sed -i '/frps/d' ~/.bashrc 2>/dev/null
sed -i '/frpc/d' ~/.bashrc 2>/dev/null
sed -i '/frps/d' ~/.profile 2>/dev/null
sed -i '/frpc/d' ~/.profile 2>/dev/null
sed -i '/frp/d' /etc/profile 2>/dev/null

# =============================
# 5. Docker 清理（重点）
# =============================
echo -e "${YELLOW}[5/6] 清理 Docker FRP...${RESET}"

if command -v docker &>/dev/null; then

    echo -e "${YELLOW}检查 frp 容器...${RESET}"
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "frp|frps|frpc" | awk '{print $1}' | xargs -r docker stop 2>/dev/null
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "frp|frps|frpc" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null

    echo -e "${YELLOW}检查 frp 镜像...${RESET}"
    docker images --format '{{.Repository}} {{.ID}}' | grep -Ei "frp" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null

    echo -e "${YELLOW}检查 frp volume...${RESET}"
    docker volume ls --format '{{.Name}}' | grep -Ei "frp" | xargs -r docker volume rm 2>/dev/null

    echo -e "${GREEN}Docker frp 清理完成${RESET}"

else
    echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
fi

# =============================
# 6. 最终检查
# =============================
echo -e "${YELLOW}[6/6] 检查残留状态...${RESET}"

frp_proc=$(ps -ef | grep -Ei "frps|frpc" | grep -v grep)

if [[ -n "$frp_proc" ]]; then
    echo -e "${RED}仍有进程残留:${RESET}"
    echo "$frp_proc"
else
    echo -e "${GREEN}无 FRP 进程残留${RESET}"
fi

# 检查端口监听（常见 7000 / 7500 / 6000）
ss -lntp 2>/dev/null | grep -Ei "7000|7500|6000|frp"

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}        FRP 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
