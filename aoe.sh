#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# 菜单项数组
menu_items=(
    "Alpine 更新"
    "Alpine 修改SSH端口"
    "Alpine 防火墙管理"
    "Alpine Fail2Ban"
    "Alpine 换源"
    "Alpine 清理"
    "Alpine 修改中文"
    "Alpine 修改主机名"
    "Alpine Docker"
    "Alpine Hysteria2"
    "Alpine 3XUI"
)

# 对应脚本命令（和菜单一一对应，保持顺序）
menu_cmds=(
    "apk update && apk add --no-cache bash curl wget vim tar sudo git"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apsdk.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apfeew.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apFail2Ban.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/aphuanyuan.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apql.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apcn.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/aphome.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/apdocker.sh)"
    "bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/aphy2.sh)"
    "bash <(curl -sL  https://raw.githubusercontent.com/Polarisiu/proxy/main/3xuiAlpine.sh)"
)

menu() {
    clear
    echo -e "${GREEN}=== Alpine 系统管理菜单 ===${RESET}"

    # 循环输出菜单
    for i in "${!menu_items[@]}"; do
        num=$((i+1))
        if [[ $num -lt 10 ]]; then
            printf "${GREEN}[0%d] %s${RESET}\n" "$num" "${menu_items[$i]}"
        else
            printf "${GREEN}[%2d] %s${RESET}\n" "$num" "${menu_items[$i]}"
        fi
    done

    # 退出项
    printf "${GREEN}[0 ] 退出${RESET}\n\n"

    read -p $'\033[32m请选择操作 (0-11): \033[0m' choice

    if [[ "$choice" == "0" ]]; then
        exit 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#menu_items[@]} )); then
        idx=$((choice-1))
        echo -e "${GREEN}正在执行: ${menu_items[$idx]}${RESET}"
        eval "${menu_cmds[$idx]}"
    else
        echo -e "${RED}无效选择，请重新输入${RESET}"
        sleep 1
    fi

    pause
}

pause() {
    read -p $'\033[32m按回车键返回菜单...\033[0m'
    menu
}

menu
