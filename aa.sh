#!/bin/bash
# ==========================================
# 服务器一键重装系统工具
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

clear

echo -e "${GREEN}"
echo "======================================"
echo "        一键重装系统工具"
echo "======================================"
echo " 1. Windows 11 Enterprise LTSC 2024"
echo " 2. Windows 10 Enterprise LTSC 2021"
echo " 3. Windows Server 2022"
echo " 4. Debian 11"
echo " 5. Debian 12"
echo " 6. Debian 13"
echo " 7. Ubuntu 22.04"
echo " 8. Ubuntu 24.04"
echo " 9. Ubuntu 25.10"
echo "10. Alpine 3.23"
echo " 0. 退出"
echo "======================================"
echo -e "${RESET}"

read -r -p $'\033[32m请选择系统 [0-10]: \033[0m' SYS_CHOICE

if [[ "$SYS_CHOICE" == "0" ]]; then
    echo -e "${YELLOW}已退出${RESET}"
    exit 0
fi

read -p "请输入 root/Administrator 密码 (用于重装系统): " SYS_PASS

if [[ -z "$SYS_PASS" ]]; then
    echo -e "${RED}密码不能为空${RESET}"
    exit 1
fi

read -p "请输入 SSH 端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -p "请输入 RDP 端口 (默认 3389): " RDP_PORT
RDP_PORT=${RDP_PORT:-3389}

echo
echo -e "${YELLOW}安装配置:${RESET}"
echo "系统密码: $SYS_PASS"
echo "SSH端口: $SSH_PORT"
echo "RDP端口: $RDP_PORT"
echo

read -p "确认开始重装系统？(y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}操作已取消${RESET}"
    exit 0
fi

echo -e "${GREEN}下载重装脚本...${RESET}"

wget -qO reinstall.sh "$SCRIPT_URL"

if [[ ! -f reinstall.sh ]]; then
    echo -e "${RED}下载失败${RESET}"
    exit 1
fi

chmod +x reinstall.sh

case $SYS_CHOICE in

1)
bash reinstall.sh windows \
--image-name "Windows 11 Enterprise LTSC 2024" \
--lang zh-cn \
--password "$SYS_PASS" \
--rdp-port "$RDP_PORT"
;;

2)
bash reinstall.sh windows \
--image-name "Windows 10 Enterprise LTSC 2021" \
--lang zh-cn \
--password "$SYS_PASS" \
--rdp-port "$RDP_PORT"
;;

3)
bash reinstall.sh windows \
--image-name "Windows Server 2022" \
--lang zh-cn \
--password "$SYS_PASS" \
--rdp-port "$RDP_PORT"
;;

4)
bash reinstall.sh debian 11 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

5)
bash reinstall.sh debian 12 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

6)
bash reinstall.sh debian 13 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

7)
bash reinstall.sh ubuntu 22.04 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

8)
bash reinstall.sh ubuntu 24.04 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

9)
bash reinstall.sh ubuntu 25.10 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

10)
bash reinstall.sh alpine 3.23 \
--password "$SYS_PASS" \
--ssh-port "$SSH_PORT"
;;

*)
echo -e "${RED}无效选项${RESET}"
exit 1
;;

esac

echo
echo -e "${GREEN}系统安装命令已执行，5秒后自动重启...${RESET}"
sleep 5
reboot
