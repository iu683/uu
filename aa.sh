#!/usr/bin/env bash
set -e

#################################
# 颜色
#################################
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "=================================="
echo " Debian 12 → Debian 13 升级脚本"
echo "=================================="
echo -e "${RESET}"

#################################
# Root检查
#################################
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请使用 root 运行${RESET}"
    exit 1
fi

#################################
# 检测系统
#################################
if ! grep -q "12" /etc/debian_version; then
    echo -e "${RED}当前不是 Debian 12${RESET}"
    cat /etc/debian_version
    exit 1
fi

echo -e "${GREEN}检测到 Debian 12${RESET}"

#################################
# 安装screen
#################################
if ! command -v screen >/dev/null 2>&1; then
    echo -e "${YELLOW}安装 screen...${RESET}"
    apt update
    apt install -y screen
fi

#################################
# screen检查
#################################
if [ -z "${STY:-}" ]; then
    echo
    echo -e "${YELLOW}建议在 screen 中运行升级${RESET}"
    echo
    echo "执行："
    echo "screen -S debian13"
    echo "然后重新运行脚本"
    echo
    read -rp "继续升级？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || exit 0
fi

#################################
# 更新 Debian12
#################################
echo -e "${CYAN}更新 Debian12 当前系统...${RESET}"

apt update
apt upgrade -y
apt full-upgrade -y
apt autoremove --purge -y

#################################
# 备份源
#################################
TIME=$(date +%F-%H%M%S)

echo -e "${CYAN}备份软件源...${RESET}"

mkdir -p /root/apt-backup-$TIME

cp /etc/apt/sources.list \
   /root/apt-backup-$TIME/ 2>/dev/null || true

cp -r /etc/apt/sources.list.d \
   /root/apt-backup-$TIME/ 2>/dev/null || true

echo -e "${GREEN}备份完成：/root/apt-backup-$TIME${RESET}"

#################################
# 检测第三方源
#################################
echo -e "${CYAN}检测第三方源...${RESET}"

THIRD=$(grep -rhvE \
'debian.org|security.debian.org|deb.debian.org|^#|^$' \
/etc/apt/sources.list* 2>/dev/null || true)

if [ -n "$THIRD" ]; then
    echo
    echo -e "${YELLOW}发现第三方源:${RESET}"
    echo "$THIRD"
    echo
    read -rp "继续升级？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || exit 0
fi

#################################
# 切换trixie
#################################
echo -e "${CYAN}切换 bookworm → trixie...${RESET}"

find /etc/apt -type f \
\( -name "*.list" -o -name "*.sources" \) \
-exec sed -i \
-e 's/bookworm/trixie/g' \
-e 's/stable/trixie/g' {} +

#################################
# 更新源
#################################
echo -e "${CYAN}更新软件源...${RESET}"

apt update

#################################
# 最小升级
#################################
echo -e "${CYAN}执行最小升级...${RESET}"

apt upgrade --without-new-pkgs -y

#################################
# 正式升级
#################################
echo
echo -e "${YELLOW}${BOLD}"
echo "开始 Debian13 正式升级"
echo "过程可能持续较久"
echo -e "${RESET}"

apt full-upgrade -y

#################################
# 清理
#################################
echo -e "${CYAN}清理系统...${RESET}"

apt autoremove --purge -y
apt clean

#################################
# 显示版本
#################################
echo
echo -e "${GREEN}${BOLD}"
cat /etc/os-release
echo -e "${RESET}"

echo
echo -e "${GREEN}升级完成，请重启${RESET}"
echo

read -rp "立即重启？[y/N]: " reboot_now

if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
    reboot
fi
