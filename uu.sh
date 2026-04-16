#!/bin/bash
# ========================================
# Docker 代理清理（仅运行容器 + 镜像）
# 修复版：正确映射运行列表索引
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

command -v docker &>/dev/null || {
    echo -e "${RED}Docker 未安装${RESET}"
    exit 1
}

# =============================
# 关键词列表
# =============================
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
# 全局运行列表（关键修复点）
# =============================
map_list=()

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
# 显示运行容器（重排）
# =============================
show_running() {
    clear
    echo -e "${GREEN}====== 正在运行的代理容器 ======${RESET}"
    echo ""

    map_list=()   # 每次刷新重建

    # 收集运行中的关键词
    for k in "${KEYWORDS[@]}"; do
        running=$(docker ps --format "{{.Names}}" | grep -Ei "$k")
        if [[ -n "$running" ]]; then
            map_list+=("$k")
        fi
    done

    # 没有运行容器
    if [[ ${#map_list[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有运行中的代理容器${RESET}"
        echo ""
        echo -e "${GREEN}[0] 退出${RESET}"
        echo ""
        return
    fi

    # 输出重排列表
    for i in "${!map_list[@]}"; do
        k="${map_list[$i]}"
        running=$(docker ps --format "{{.Names}}" | grep -Ei "$k")

        echo -e "${YELLOW}[$((i+1))] $k${RESET}"
        echo "$running" | sed 's/^/  🟢 /'
        echo ""
    done

    echo -e "${RED}[a] 清理全部运行容器${RESET}"
    echo -e "${GREEN}[0] 退出${RESET}"
}

# =============================
# 全部清理
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

    # 一键清理
    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        echo -e "${RED}清理所有运行中的代理容器 + 镜像...${RESET}"
        run_all
        echo -e "${GREEN}完成${RESET}"
        read -p "回车继续..."
        continue
    fi

    # 数字选择（关键修复）
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice-1))

        if [[ $idx -ge 0 && $idx -lt ${#map_list[@]} ]]; then
            k="${map_list[$idx]}"

            echo -e "${YELLOW}清理中: $k${RESET}"
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
