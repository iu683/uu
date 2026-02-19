#!/bin/bash
# 多系统永久 DNS 修改脚本

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG_DIR="/etc/systemd/resolved.conf.d"
CONFIG_FILE="$CONFIG_DIR/custom_dns.conf"

echo -e "${GREEN}=== 系统永久 DNS 配置工具 ===${RESET}"

# 输入主 DNS
read -p $'\033[32m请输入主 DNS (例如 8.8.8.8): \033[0m' MAIN_DNS
# 输入备用 DNS
read -p $'\033[32m请输入备用 DNS (可留空，多个用空格): \033[0m' BACKUP_DNS

if [[ -z "$MAIN_DNS" ]]; then
    echo -e "${RED}错误: 主 DNS 不能为空！${RESET}"
    exit 1
fi

echo
echo -e "${GREEN}即将应用以下配置：${RESET}"
echo -e "DNS=$MAIN_DNS"
echo -e "FallbackDNS=$BACKUP_DNS"
read -p $'\033[32m确认继续? (y/n): \033[0m' CONFIRM
[[ "$CONFIRM" != "y" ]] && echo -e "${RED}已取消${RESET}" && exit 0

echo
echo -e "${YELLOW}正在检测系统 DNS 管理方式...${RESET}"

# 检测 systemd-resolved
if systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
    if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then

        echo -e "${GREEN}检测到 systemd-resolved，使用 resolved 模式${RESET}"

        sudo mkdir -p "$CONFIG_DIR"

        sudo bash -c "cat > $CONFIG_FILE <<EOF
[Resolve]
DNS=$MAIN_DNS
FallbackDNS=$BACKUP_DNS
EOF"

        sudo systemctl restart systemd-resolved

        echo -e "${GREEN}已通过 systemd-resolved 永久生效！${RESET}"
        echo
        resolvectl status | grep -E 'DNS Servers|Fallback DNS Servers'
        exit 0
    fi
fi

# 如果没有 systemd-resolved
echo -e "${YELLOW}未检测到 systemd-resolved，使用 resolv.conf 模式${RESET}"

sudo chattr -i /etc/resolv.conf 2>/dev/null
sudo cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

sudo bash -c "cat > /etc/resolv.conf <<EOF
nameserver $MAIN_DNS
$(for dns in $BACKUP_DNS; do echo nameserver $dns; done)
EOF"

read -p $'\033[32m是否锁定 resolv.conf 防止被覆盖? (y/n): \033[0m' LOCK
if [[ "$LOCK" == "y" ]]; then
    sudo chattr +i /etc/resolv.conf 2>/dev/null
    echo -e "${GREEN}已锁定 resolv.conf${RESET}"
fi

echo
echo -e "${GREEN}当前 DNS:${RESET}"
cat /etc/resolv.conf
