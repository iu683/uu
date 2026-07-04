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

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
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
    echo -e "${GREEN}========================${RESET}"
    echo -e "${GREEN}    ◈ 订阅节点检测 ◈    ${RESET}"
    echo -e "${GREEN}========================${RESET}"
    echo
    echo -e "${YELLOW}支持协议:${RESET}"
    echo -e "${YELLOW}VLESS / VMess / Trojan / SS / SOCKS / WireGuard / Hysteria2${RESET}"
    echo

    read -p "$(echo -e "${YELLOW}请输入节点链接: ${RESET}")" PROXY_URL

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
        "$IMAGE" -f

    echo
    echo -e "${GREEN}检测结束，已自动删除${RESET}"
    echo

    read -p "$(echo -e "${YELLOW}按回车继续...${RESET}")"
}

# ========================================
# 主菜单
# ========================================

menu() {

    check_dependencies

    while true; do

        clear
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}  ◈   订阅节点检测   ◈  ${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN}1) 开始检测${RESET}"
        echo -e "${GREEN}2) 更新检测${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        echo -e "${GREEN}========================${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) run_test ;;
            2) pull_image ; read -p "$(echo -e "${YELLOW}按回车继续...${RESET}")" ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}" ; sleep 1 ;;
        esac
    done
}

menu
