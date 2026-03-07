#!/bin/sh

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/AZAPReality.sh"

install_reality() {
    echo -e "${GREEN}正在安装 Reality...${RESET}"
    sh -c "$(curl -sL $SCRIPT_URL)"
}

uninstall_reality() {
    echo -e "${GREEN}正在卸载 Reality...${RESET}"
    sh -c "$(curl -sL $SCRIPT_URL)" uninstall
}

pause() {
    printf "\033[32m按回车继续...\033[0m"
    read tmp
}

menu() {
    while true
    do
        clear
        echo "=============================="
        echo "        Reality 管理工具"
        echo "=============================="
        echo " 1) 安装 Reality"
        echo " 2) 卸载 Reality"
        echo " 0) 退出"
        printf " 请选择: "
        read choice

        case "$choice" in
            1)
                install_reality
                pause
                ;;
            2)
                uninstall_reality
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                echo "输入错误，请重新选择"
                sleep 1
                ;;
        esac
    done
}

menu
