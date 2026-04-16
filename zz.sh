#!/bin/bash
# ========================================
# Docker 代理清理（显示运行容器 + 镜像）
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
# 获取容器
# =============================
get_containers() {
    docker ps -a --format "{{.Names}}" | grep -Ei "$1"
}

# =============================
# 删除容器
# =============================
del_container() {
    docker ps -a --format "{{.Names}}" | grep -Ei "$1" | xargs -r docker rm -f >/dev/null 2>&1
}

# =============================
# 删除镜像
# =============================
del_image() {
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -Ei "$1" | awk '{print $2}' | xargs -r docker rmi -f >/dev/null 2>&1
}

# =============================
# 显示状态面板
# =============================
show_status() {
    clear
    echo -e "${YELLOW}========== Docker 代理运行状态 ==========${RESET}"
    echo ""

    i=1
    for k in "${KEYWORDS[@]}"; do
        containers=$(get_containers "$k")
        running=$(echo "$containers" | xargs -r docker ps --format "{{.Names}}" 2>/dev/null | grep -Ei "$k")

        echo -e "${GREEN}[$i] $k${RESET}"

        if [[ -n "$containers" ]]; then
            echo -e "  📦 容器:"
            echo "$containers" | sed 's/^/    - /'
        else
            echo -e "  📦 容器: 无"
        fi

        if [[ -n "$running" ]]; then
            echo -e "  🟢 运行中: $running"
        else
            echo -e "  ⚪ 运行中: 无"
        fi

        echo ""
        ((i++))
    done

    echo -e "${RED}[a] 清理全部（容器+镜像）${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
    echo ""
}

# =============================
# 全部清理
# =============================
run_all() {
    for k in "${KEYWORDS[@]}"; do
        del_container "$k"
        del_image "$k"
        echo -e "${GREEN}✔ 已清理 $k${RESET}"
    done
}

# =============================
# 主循环
# =============================
while true; do
    show_status
    read -p "请选择: " choice
    choice=$(echo "$choice" | xargs)

    [[ "$choice" == "0" ]] && exit 0

    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        echo -e "${RED}开始清理全部容器 + 镜像...${RESET}"
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
