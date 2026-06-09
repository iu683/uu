#!/bin/bash
# ========================================
# 1Panel 管理脚本 (菜单直接显示状态版)
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
        echo -e "${RED}未检测到 1pctl，请确认 1Panel 已安装。若未安装，请选择选项 18${RESET}"
        return 1
    fi
    return 0
}

pause(){
    read -rp "按回车继续..."
}

menu(){
clear
echo -e "${GREEN}======================================${RESET}"
echo -e "${GREEN}        1Panel 快捷管理菜单           ${RESET}"
echo -e "${GREEN}======================================${RESET}"

# ----- 核心改动：在菜单顶部直接提取并显示实时状态 -----
if command -v $CMD &>/dev/null; then
    # 提取状态（判断是否包含 running）
    local status_info=$($CMD status all 2>/dev/null)
    if echo "$status_info" | grep -q "running"; then
        echo -e "服务状态: ${GREEN}● 正在运行 (Running)${RESET}"
    else
        echo -e "服务状态: ${RED}○ 已停止 (Stopped)${RESET}"
    fi

    # 提取版本号 (去掉多余换行和空格)
    local ver_info=$($CMD version 2>/dev/null | grep -i "version" | awk '{print $2}')
    echo -e "当前版本: ${YELLOW}${ver_info:-未知}${RESET}"

    # 提取端口、安全入口等关键面板信息
    local user_info=$($CMD user-info 2>/dev/null)
    local port=$(echo "$user_info" | grep -i "port" | awk -F': ' '{print $2}')
    local entrance=$(echo "$user_info" | grep -i "entrance" | awk -F': ' '{print $2}')
    
    echo -e "面板端口: ${CYAN}${port:-未知}${RESET}  |  安全入口: ${CYAN}${entrance:-无}${RESET}"
else
    echo -e "核心状态: ${RED}未检测到 1Panel 环境，请先执行选项 18 进行安装${RESET}"
fi
echo -e "${GREEN}======================================${RESET}"

# ----- 菜单选项列表 -----
echo -e "${GREEN} 1.运行状态详情${RESET}  | ${GREEN} 2.启动服务${RESET}  | ${GREEN} 3.停止服务${RESET}  | ${GREEN} 4.重启服务${RESET}"
echo "------------------------------------------------"
echo -e "${GREEN} 5.修改用户名${RESET}    | ${GREEN} 6.修改密码${RESET}  | ${GREEN} 7.修改面板端口${RESET}"
echo "------------------------------------------------"
echo -e "${GREEN} 8.取消安全入口${RESET}  | ${GREEN} 9.取消HTTPS ${RESET} | ${GREEN}10.取消IP限制${RESET}"
echo -e "${GREEN}11.取消两步验证${RESET}  | ${GREEN}12.取消域名绑定${RESET}"
echo "------------------------------------------------"
echo -e "${GREEN}13.监听 IPv4${RESET}     | ${GREEN}14.监听 IPv6${RESET}"
echo "------------------------------------------------"
echo -e "${GREEN}15.详细版本查看${RESET}  | ${GREEN}16.完整用户信息${RESET}"
echo "------------------------------------------------"
echo -e "${CYAN}18.在线安装 1Panel${RESET} | ${RED}17.彻底卸载 1Panel${RESET}"
echo "------------------------------------------------"
echo -e "${GREEN} 0.退出脚本${RESET}"
echo
}

while true
do
    menu
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r num

    case "$num" in

    1)
    if check_cmd; then $CMD status all; fi
    pause
    ;;

    2)
    if check_cmd; then $CMD start all; fi
    # 稍微延迟让服务启动，方便刷新菜单直接看到新状态
    sleep 1.5
    ;;

    3)
    if check_cmd; then $CMD stop all; fi
    sleep 1.5
    ;;

    4)
    if check_cmd; then $CMD restart all; fi
    sleep 1.5
    ;;

    5)
    if check_cmd; then
        echo -ne "${YELLOW}请输入新的用户名: ${RESET}"
        read -r input_username
        if [ -z "$input_username" ]; then
            echo -e "${RED}用户名不能为空${RESET}"
        else
            $CMD update username "$input_username"
        fi
    fi
    pause
    ;;

    6)
    if check_cmd; then
        echo -ne "${YELLOW}请输入新的密码: ${RESET}"
        read -r input_password
        if [ -z "$input_password" ]; then
            echo -e "${RED}密码不能为空${RESET}"
        else
            $CMD update password "$input_password"
        fi
    fi
    pause
    ;;

    7)
    if check_cmd; then
        echo -ne "${YELLOW}请输入新的端口号: ${RESET}"
        read -r input_port
        if [[ ! "$input_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}端口必须是纯数字${RESET}"
        else
            $CMD update port "$input_port"
        fi
    fi
    pause
    ;;

    8)
    if check_cmd; then $CMD reset entrance; fi
    pause
    ;;

    9)
    if check_cmd; then $CMD reset https; fi
    pause
    ;;

    10)
    if check_cmd; then $CMD reset ips; fi
    pause
    ;;

    11)
    if check_cmd; then $CMD reset mfa; fi
    pause
    ;;

    12)
    if check_cmd; then $CMD reset domain; fi
    pause
    ;;

    13)
    if check_cmd; then $CMD listen-ip ipv4; fi
    pause
    ;;

    14)
    if check_cmd; then $CMD listen-ip ipv6; fi
    pause
    ;;

    15)
    if check_cmd; then $CMD version; fi
    pause
    ;;

    16)
    if check_cmd; then $CMD user-info; fi
    pause
    ;;

    17)
    if check_cmd; then $CMD uninstall; fi
    pause
    ;;

    18)
    if command -v $CMD &>/dev/null; then
        echo -e "${YELLOW}检测到系统已安装 1Panel，无需重复安装！${RESET}"
    else
        echo -e "${GREEN}正在安装 1Panel...${RESET}"
        bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
        sleep 2
    fi
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
