#!/bin/bash
# ========================================
# Docker 代理容器 + 镜像清理
# 仅：容器 + 镜像
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

command -v docker &>/dev/null || {
    echo -e "${RED}Docker 未安装${RESET}"
    exit 1
}

KEYWORDS=(
"xray"
"sing"
"hysteria"
"tuic"
"snell"
"3xui"
"AnyTLSD"
"MTProto"
"shadowsocks"
"shadow-tls"
"Singbox-AnyReality"
"Singbox-AnyTLS"
"Singbox-TUICv5"
"Xray-Reality"
"Xray-Realityxhttp"
"xray-socks5"
"xray-vmess"
"xray-vmesstls"
"clash"
"mihomo"
"warp"
"glash"
"conflux"
"heki"
"microwarp"
"nodepassdash"
"ppanel"
"wg-easy"
"wireguard"
"gostpanel"
"vite-frontend"
"xboard"
)

del_container() {
    local key="$1"
    docker ps -a --format "{{.Names}}" | grep -Ei "$key" | xargs -r docker rm -f >/dev/null 2>&1
}

del_image() {
    local key="$1"
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -Ei "$key" | awk '{print $2}' | xargs -r docker rmi -f >/dev/null 2>&1
}

show_menu() {
    clear
    echo -e "${YELLOW}====== Docker 代理清理======${RESET}"
    echo ""

    i=1
    for k in "${KEYWORDS[@]}"; do
        echo -e "${GREEN}[$i] $k${RESET}"
        ((i++))
    done

    echo ""
    echo -e "${RED}[a] 全部清理${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    echo ""
}

run_all() {
    for k in "${KEYWORDS[@]}"; do
        del_container "$k"
        del_image "$k"
        echo -e "${GREEN}✔ $k 已清理${RESET}"
    done
}

while true; do
    show_menu
    read -p "请选择: " choice
    choice=$(echo "$choice" | xargs)

    [[ "$choice" == "0" ]] && exit 0

    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        echo -e "${RED}开始清理全部容器+镜像...${RESET}"
        run_all
        read -p "回车继续..."
        continue
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#KEYWORDS[@]} ]]; then
            k="${KEYWORDS[$idx]}"
            del_container "$k"
            del_image "$k"
            echo -e "${GREEN}✔ $k 清理完成${RESET}"
        else
            echo -e "${RED}无效选项${RESET}"
        fi
    else
        echo -e "${RED}输入错误${RESET}"
    fi

    read -p "回车继续..."
done
