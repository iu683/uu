#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

LXD_INSTALL="https://raw.githubusercontent.com/xkatld/lxdapi-web-server/refs/heads/main-stable/Shell/lxd_install.sh"
API_INSTALL="https://raw.githubusercontent.com/xkatld/lxdapi-web-server/refs/heads/main-stable/Shell/lxdapi_install.sh"
API_UPDATE="https://raw.githubusercontent.com/xkatld/lxdapi-web-server/refs/heads/main-stable/Shell/lxdapi_update.sh"
STORAGE_POOL="https://raw.githubusercontent.com/xkatld/lxdapi-web-server/refs/heads/main-stable/Shell/storage_pool.sh"
IMAGE_IMPORT="https://raw.githubusercontent.com/xkatld/lxdapi-web-server/refs/heads/main-stable/Shell/image_import.sh"
IMAGE_ADD="https://raw.githubusercontent.com/xkatld/zjmf-lxd-server/refs/heads/main/install/lxdimages.sh"
IMAGE_XX="https://raw.githubusercontent.com/sistarry/toolbox/main/toy/LXDAPIX.sh"

run() {
    url=$1
    name=$2
    echo -e "${GREEN}正在执行：${name}...${RESET}"
    bash <(curl -Ls "$url")
    pause
}

pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m'
    menu
}

show_ip() {
    echo -e "${GREEN}当前公网网卡信息：${RESET}"
    ip ad
    pause
}

menu() {
    clear
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}        LXDAPI 管理工具         ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1) 安装 LXD${RESET}"
    echo -e "${GREEN} 2) 部署 LXDAPI${RESET}"
    echo -e "${GREEN} 3) 更新 LXDAPI${RESET}"
    echo -e "${GREEN} 4) 管理存储池${RESET}"
    echo -e "${GREEN} 5) 管理镜像${RESET}"
    echo -e "${GREEN} 6) 新增镜像${RESET}"
    echo -e "${GREEN} 7) 查看公网网卡${RESET}"
    echo -e "${GREEN} 8) LXDAPI面板信息${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    read -p $'\033[32m 请选择: \033[0m' choice

    case $choice in
        1) run "$LXD_INSTALL" "安装 LXD" ;;
        2) run "$API_INSTALL" "部署 LXDAPI" ;;
        3) run "$API_UPDATE" "更新 LXDAPI" ;;
        4) run "$STORAGE_POOL" "存储池管理" ;;
        5) run "$IMAGE_IMPORT" "镜像管理" ;;
        6) run "$IMAGE_ADD" "新增镜像" ;;
        7) show_ip ;;
        8) run "$IMAGE_XX" "面板信息" ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}输入错误，请重新选择${RESET}"
            sleep 1
            menu
            ;;
    esac
}

menu
