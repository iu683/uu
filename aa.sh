#!/bin/bash
# ==========================================
# systemd-resolved 一键修复脚本
# 自动启用 + 修复 resolv.conf
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}==== systemd-resolved 一键修复 ====${RESET}"

# =============================
# 检测 root
# =============================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

# =============================
# 检测 systemd 是否存在
# =============================
if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}当前系统不支持 systemd${RESET}"
    exit 1
fi

# =============================
# 启用并启动服务
# =============================
echo -e "${YELLOW}正在启用并启动 systemd-resolved...${RESET}"
systemctl enable --now systemd-resolved >/dev/null 2>&1
systemctl restart systemd-resolved

sleep 1

# =============================
# 检查服务状态
# =============================
if systemctl is-active --quiet systemd-resolved; then
    echo -e "${GREEN}systemd-resolved 运行正常 ✔${RESET}"
else
    echo -e "${RED}systemd-resolved 启动失败！${RESET}"
    systemctl status systemd-resolved
    exit 1
fi

# =============================
# 修复 resolv.conf
# =============================
echo -e "${YELLOW}修复 /etc/resolv.conf ...${RESET}"

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# =============================
# 验证链接
# =============================
echo -e "${YELLOW}检查 resolv.conf 状态...${RESET}"
RESOLV_LINK=$(readlink -f /etc/resolv.conf)

if [[ "$RESOLV_LINK" == "/run/systemd/resolve/stub-resolv.conf" ]]; then
    echo -e "${GREEN}resolv.conf 修复成功 ✔${RESET}"
else
    echo -e "${RED}resolv.conf 修复异常，请手动检查！${RESET}"
fi

echo
echo -e "${GREEN}当前 resolv.conf 指向：${RESET}"
ls -l /etc/resolv.conf

echo
echo -e "${GREEN}修复完成！${RESET}"
