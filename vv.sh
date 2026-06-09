#!/bin/bash
# ========================================
# 1Panel 管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

CMD="1pctl"

# 检查命令
check_cmd() {
    if ! command -v $CMD &>/dev/null; then
        echo -e "${RED}未检测到 1pctl，请确认 1Panel 已安装${RESET}"
        exit 1
    fi
}

pause(){
    read -rp "按回车继续..."
}

menu(){
clear
echo -e "${GREEN}"
echo "======================================"
echo "        1Panel 管理菜单"
echo "======================================"
echo -e "${RESET}"

echo -e "${GREEN} 1.查看 1Panel 状态${RESET} "
echo -e "${GREEN} 2.启动 1Panel${RESET} "
echo -e "${GREEN} 3.停止 1Panel${RESET} "
echo -e "${GREEN} 4.重启 1Panel${RESET} "

echo "-----------------------------"

echo -e "${GREEN} 5.修改用户名${RESET} "
echo -e "${GREEN} 6.修改密码${RESET} "
echo -e "${GREEN} 7.修改面板端口${RESET} "

echo "-----------------------------"

echo -e "${GREEN} 8.取消安全入口${RESET} "
echo -e "${GREEN} 9.取消 HTTPS 登录${RESET} "
echo -e "${GREEN}10.取消 IP 限制${RESET} "
echo -e "${GREEN}11.取消两步验证${RESET} "
echo -e "${GREEN}12.取消域名绑定${RESET} "

echo "-----------------------------"

echo -e "${GREEN}13.监听 IPv4${RESET} "
echo -e "${GREEN}14.监听 IPv6${RESET} "

echo "-----------------------------"

echo -e "${GREEN}15.查看版本${RESET} "
echo -e "${GREEN}16.获取用户信息${RESET} "

echo "-----------------------------"

echo -e "${GREEN}17.卸载 1Panel${RESET} "

echo "-----------------------------"

echo -e "${GREEN} 0.退出${RESET} "
echo
}

check_cmd

while true
do
    menu
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r num

    case "$num" in

    1)
    $CMD status all
    pause
    ;;

    2)
    $CMD start all
    pause
    ;;

    3)
    $CMD stop all
    pause
    ;;

    4)
    $CMD restart all
    pause
    ;;

    5)
    echo -ne "${YELLOW}请输入新的用户名: ${RESET}"
    read -r input_username
    if [ -z "$input_username" ]; then
        echo -e "${RED}用户名不能为空${RESET}"
    else
        $CMD update username "$input_username"
    fi
    pause
    ;;

    6)
    echo -ne "${YELLOW}请输入新的密码: ${RESET}"
    read -r input_password
    if [ -z "$input_password" ]; then
        echo -e "${RED}密码不能为空${RESET}"
    else
        $CMD update password "$input_password"
    fi
    pause
    ;;

    7)
    echo -ne "${YELLOW}请输入新的端口号: ${RESET}"
    read -r input_port
    if [[ ! "$input_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口必须是纯数字${RESET}"
    else
        $CMD update port "$input_port"
    fi
    pause
    ;;

    8)
    $CMD reset entrance
    pause
    ;;

    9)
    $CMD reset https
    pause
    ;;

    10)
    $CMD reset ips
    pause
    ;;

    11)
    $CMD reset mfa
    pause
    ;;

    12)
    $CMD reset domain
    pause
    ;;

    13)
    $CMD listen-ip ipv4
    pause
    ;;

    14)
    $CMD listen-ip ipv6
    ;;

    15)
    $CMD version
    pause
    ;;

    16)
    $CMD user-info
    pause
    ;;

    17)
    $CMD uninstall
    pause
    ;;

    0)
    exit
    ;;

    *)
    echo -e "${RED}无效选项${RESET}"
    sleep 1
    ;;

    esac
done
