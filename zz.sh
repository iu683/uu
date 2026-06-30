#!/bin/bash
# ==========================================
# FRP-Panel 一键管理菜单脚本
# ==========================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW="\033[33m"
RED='\033[0;31m'
NC='\033[0m'
RESET='\033[0m'

# GitHub 代理节点列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 核心下载执行函数：一个一个尝试代理，直到成功
download_and_run() {
    local script_path="$1"
    local success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="${proxy}${script_path}"
        echo
        
        # 尝试下载并直接用 bash 执行
        # -f 让 curl 在服务器返回 404/500 等错误时报错退出，以便触发 || 继续循环
        if bash <(curl -fsSL "$url"); then
            success=true
            break
        fi
        
        echo -e "${RED}当前接口下载失败，正在尝试下一个...${NC}"
    done

    if [ "$success" = false ]; then
        echo -e "${RED}错误：所有代理节点及直连均已尝试，下载失败，请检查网络！${NC}"
    fi
}

while true; do
    clear
    # 检测安装状态
    if [ -d "/opt/frpp-master" ]; then
        MSTATUS="${YELLOW}[已安装]${NC}"
    else
        MSTATUS="${RED}[未安装]${NC}"
    fi
    # 检测安装状态
    if [ -d "/opt/frp-panel-server" ]; then
        SSTATUS="${YELLOW}[已安装]${NC}"
    else
        SSTATUS="${RED}[未安装]${NC}"
    fi
    # 检测安装状态
    if [ -d "/opt/frp-panel-client" ]; then
        STATUS="${YELLOW}[已安装]${NC}"
    else
        STATUS="${RED}[未安装]${NC}"
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  FRP-Panel 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 面板端状态: ${MSTATUS}"
    echo -e "${GREEN} 服务端状态: ${SSTATUS}"
    echo -e "${GREEN} 客户端状态: ${STATUS}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}1. Master 面板端${NC}"
    echo -e "${GREEN}2. Server 服务端${NC}"
    echo -e "${GREEN}3. Client 客户端${NC}"
    echo -e "${GREEN}0. 退出${NC}"
    echo -e "${GREEN}================================${RESET}"
    read -rp "$(echo -e "${GREEN}请输入编号:${NC} ")" choice

    case $choice in
        1|01)
            download_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/frp-panel-maste.sh"
            ;;
        2|02)
            download_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/frp-panel-server.sh"
            ;;
        3|03)
            download_and_run "https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/frp-panel-client.sh"
            ;;
        0|00)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${NC}"
            ;;
    esac

    read -p "$(echo -e "${GREEN}按回车返回菜单...${RESET}")" temp
done
