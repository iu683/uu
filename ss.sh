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
echo "         一键重装系统工具"
echo "======================================"
echo " 1. Windows 11 Enterprise LTSC 2024"
echo " 2. Windows 10 Enterprise LTSC 2021"
echo " 3. Windows Server 2022"
echo " 4. Debian 11"
echo " 5. Debian 12"
echo " 6. Debian 13"
echo " 7. Ubuntu 22.04"
echo " 8. Ubuntu 24.04"
echo " 9. Ubuntu 26.04"
echo "10. Alpine 3.23"
echo " 0. 退出"
echo "======================================"
echo -e "${RESET}"

read -r -p $'\033[32m请选择系统 [0-10]: \033[0m' SYS_CHOICE

if [[ "$SYS_CHOICE" == "0" ]]; then

    exit 0
fi

# 基础配置输入
read -p "请输入系统密码 (若使用SSH公钥登录，此处可直接回车): " SYS_PASS
read -p "请输入自定义用户名 (默认root): " CUSTOM_USER
read -p "请输入 SSH 公钥 (留空则不配置): " SSH_KEY

# 核心逻辑：密码与公钥二选一校验
if [[ -z "$SYS_PASS" && -z "$SSH_KEY" ]]; then
    echo -e "${RED}错误：密码 和 SSH公钥 不能同时为空！${RESET}"
    exit 1
fi

read -p "请输入 SSH 端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -p "请输入 RDP 端口 (默认 3389): " RDP_PORT
RDP_PORT=${RDP_PORT:-3389}

# 动态构建 Linux 的附加参数
EXTRA_ARGS=""
if [[ -n "$CUSTOM_USER" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --username $CUSTOM_USER"
fi
if [[ -n "$SSH_KEY" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --ssh-key '$SSH_KEY'"
fi
if [[ -n "$SYS_PASS" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --password $SYS_PASS"
fi

echo
echo -e "${YELLOW}安装配置确认:${RESET}"
if [[ "$SYS_CHOICE" =~ ^[1-3]$ ]]; then
    echo "系统类型: Windows"
    echo "用户名: Administrator"
    echo "系统密码: ${SYS_PASS:-（未设置，请确保原镜像有默认密码）}"
    echo "RDP 端口: $RDP_PORT"
else
    echo "系统类型: Linux / Alpine"
    echo "用户名: ${CUSTOM_USER:-root}"
    echo "系统密码: ${SYS_PASS:-（未设置，将使用公钥登录）}"
    echo "SSH 端口: $SSH_PORT"
    echo "SSH 公钥: ${SSH_KEY:0:30}...（截取显示）"
fi
echo

read -p "确认开始重装系统？(y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}操作已取消${RESET}"
    exit 0
fi

echo -e "${GREEN}下载重装...${RESET}"
wget -qO reinstall.sh "$SCRIPT_URL"

if [[ ! -f reinstall.sh ]]; then
    echo -e "${RED}下载失败，请检查网络或 URL 是否有效${RESET}"
    exit 1
fi

chmod +x reinstall.sh

# 执行重装逻辑
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
bash reinstall.sh debian 11 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

5)
bash reinstall.sh debian 12 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

6)
bash reinstall.sh debian 13 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

7)
bash reinstall.sh ubuntu 22.04 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

8)
bash reinstall.sh ubuntu 24.04 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

9)
bash reinstall.sh ubuntu 26.04 --ssh-port "$SSH_PORT" $EXTRA_ARGS
;;

10)
bash reinstall.sh alpine 3.23 --ssh-port "$SSH_PORT" $EXTRA_ARGS
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
