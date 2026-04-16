#!/bin/bash
# ========================================
# Docker 代理清理（仅运行容器列表）
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
"xboard"
)

# =============================
# 删除容器
# =============================
del_container() {
    docker ps --format "{{.Names}}" | grep -Ei "$1" | xargs -r docker rm -f >/dev/null 2>&1
}

# =============================
# 删除镜像
# =============================
del_image() {
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -Ei "$1" | awk '{print $2}' | xargs -r docker rmi -f >/dev/null 2>&1
}

# =============================
# 仅获取运行容器
# =============================
get_running() {
    docker ps --format "{{.Names}}" | grep -Ei "$1"
}

# =============================
# 显示运行列表
# =============================
show_running() {
    clear
    echo -e "${YELLOW}====== 正在运行的代理容器 ======${RESET}"
    echo ""

    i=1
    HAS_ANY=0

    for k in "${KEYWORDS[@]}"; do
        running=$(get_running "$k")

        if [[ -n "$running" ]]; then
            HAS_ANY=1
            echo -e "${GREEN}[$i] $k${RESET}"
            echo "$running" | sed 's/^/  🟢 /'
            echo ""
        fi

        ((i++))
    done

    if [[ $HAS_ANY -eq 0 ]]; then
        echo -e "${YELLOW}当前没有运行中的代理容器${RESET}"
        echo ""
    fi

    echo -e "${RED}[a] 清理全部运行容器${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    echo ""
}

# =============================
# 全部清理（仅运行容器）
# =============================
run_all() {
    for k in "${KEYWORDS[@]}"; do
        del_container "$k"
        del_image "$k"
    done
}

# =============================
# 主循环
# =============================
while true; do
    show_running
    read -p "请选择: " choice
    choice=$(echo "$choice" | xargs)

    [[ "$choice" == "0" ]] && exit 0

    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        echo -e "${RED}清理所有运行中的代理容器 + 镜像...${RESET}"
        run_all
        echo -e "${GREEN}完成${RESET}"
        read -p "回车继续..."
        continue
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#KEYWORDS[@]} ]]; then
            k="${KEYWORDS[$idx]}"
            del_container "$k"
            del_image "$k"
            echo -e "${GREEN}✔ 已清理 $k${RESET}"
        else
            echo -e "${RED}无效选项${RESET}"
        fi
    else
        echo -e "${RED}输入错误${RESET}"
    fi

    read -p "回车继续..."
done
