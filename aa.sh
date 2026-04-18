#!/bin/bash
# ========================================
# Realm 彻底卸载脚本
# 支持：systemd / docker / 手动安装 / 进程 / 配置清理
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${RED}========================================${RESET}"
echo -e "${RED}        Realm 彻底卸载${RESET}"
echo -e "${RED}========================================${RESET}"

# =============================
# 1. 停止 systemd 服务
# =============================
echo -e "${YELLOW}[1/6] 停止 systemd 服务...${RESET}"

systemctl stop realm 2>/dev/null
systemctl disable realm 2>/dev/null

systemctl stop realm@* 2>/dev/null
systemctl disable realm@* 2>/dev/null

# 删除 service 文件
rm -f /etc/systemd/system/realm.service
rm -f /etc/systemd/system/realm@*.service
systemctl daemon-reload 2>/dev/null

# =============================
# 2. 停止进程
# =============================
echo -e "${YELLOW}[2/6] 清理运行进程...${RESET}"

pkill -f realm 2>/dev/null

# =============================
# 3. 删除二进制文件
# =============================
echo -e "${YELLOW}[3/6] 删除程序文件...${RESET}"

rm -f /usr/bin/realm
rm -f /usr/local/bin/realm
rm -f /bin/realm

rm -rf /opt/realm
rm -rf /etc/realm
rm -rf /var/lib/realm
rm -rf ~/.realm

# =============================
# 4. 清理配置文件
# =============================
echo -e "${YELLOW}[4/6] 清理配置文件...${RESET}"

rm -f /etc/realm.json
rm -f /etc/realm/config.json
rm -f /usr/local/etc/realm.json

# =============================
# 5. Docker 清理（重点）
# =============================
echo -e "${YELLOW}[5/6] 清理 Docker Realm 相关...${RESET}"

if command -v docker &>/dev/null; then

    # 容器
    echo -e "${YELLOW}检查 realm 容器...${RESET}"
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "realm" | awk '{print $1}' | xargs -r docker stop 2>/dev/null
    docker ps -a --format '{{.ID}} {{.Names}}' | grep -Ei "realm" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null

    # 镜像
    echo -e "${YELLOW}检查 realm 镜像...${RESET}"
    docker images --format '{{.Repository}} {{.ID}}' | grep -Ei "realm" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null

    # volume
    echo -e "${YELLOW}检查 realm volume...${RESET}"
    docker volume ls --format '{{.Name}}' | grep -Ei "realm" | xargs -r docker volume rm 2>/dev/null

    echo -e "${GREEN}Docker realm 清理完成${RESET}"

else
    echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
fi

# =============================
# 6. 检测端口占用残留
# =============================
echo -e "${YELLOW}[6/6] 检测端口/残留进程...${RESET}"

realm_proc=$(ps -ef | grep -Ei "realm" | grep -v grep)

if [[ -n "$realm_proc" ]]; then
    echo -e "${RED}仍有进程残留:${RESET}"
    echo "$realm_proc"
else
    echo -e "${GREEN}无 realm 进程残留${RESET}"
fi

# 检查常见端口占用（realm 常用于转发）
ss -lntp 2>/dev/null | grep -Ei "realm"

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}        Realm 已彻底卸载完成${RESET}"
echo -e "${GREEN}========================================${RESET}"
