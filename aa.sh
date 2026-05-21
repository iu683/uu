#!/bin/bash
# ========================================
# IPQuality Proxy 临时检测脚本
# 每次输入节点 → 自动测试 → 自动删除容器
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

IMAGE="registry.gitlab.com/mr-potato/ipquality-proxy:latest"

# ========================================
# 检测 Docker
# ========================================

check_docker() {

    if ! command -v docker &>/dev/null; then

        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"

        curl -fsSL https://get.docker.com | bash

        systemctl enable docker
        systemctl start docker
    fi
}

# ========================================
# 拉取镜像
# ========================================

pull_image() {

    echo -e "${GREEN}正在更新镜像...${RESET}"

    docker pull "$IMAGE"
}

# ========================================
# 开始检测
# ========================================

run_test() {

    clear

    echo -e "${GREEN}=== IPQuality Proxy 临时检测 ===${RESET}"
    echo
    echo -e "${YELLOW}支持协议:${RESET}"
    echo -e "VLESS / VMess / Trojan / SS / SOCKS / WireGuard / Hysteria2"
    echo

    read -p "请输入节点链接: " PROXY_URL

    if [ -z "$PROXY_URL" ]; then

        echo -e "${RED}节点不能为空${RESET}"
        sleep 2
        return
    fi

    echo
    echo -e "${GREEN}开始检测，请稍候...${RESET}"
    echo

    docker run --rm -it \
        --name ipquality-proxy-test \
        --network host \
        -e PROXY_URL="$PROXY_URL" \
        "$IMAGE" -f -p

    echo
    echo -e "${GREEN}检测结束，容器已自动删除${RESET}"
    echo

    read -p "按回车继续..."
}

# ========================================
# 主菜单
# ========================================

menu() {

    check_docker

    while true; do

        clear

        echo -e "${GREEN}=== IPQuality Proxy 临时检测菜单 ===${RESET}"
        echo -e "${GREEN}1) 开始检测${RESET}"
        echo -e "${GREEN}2) 更新镜像${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) run_test ;;
            2) pull_image ; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
