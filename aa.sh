#!/bin/bash
# ==========================================
# Cloudflare DDNS 一键管理菜单脚本
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
    'https://ghfast.top/'
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
    if [ -d "/usr/local/bin/ddns" ] || [ -f "/usr/local/bin/ddns" ]; then
        MSTATUS="${YELLOW}[已安装]${NC}"
    else
        MSTATUS="${RED}[未安装]${NC}"
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Cloudflare DDNS 工具  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 当前状态: ${MSTATUS}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}1. 安装${NC}"
    echo -e "${GREEN}2. 卸载${NC}"
    echo -e "${GREEN}0. 退出${NC}"
    echo -e "${GREEN}================================${RESET}"
    read -rp "$(echo -e "${GREEN}请输入编号:${NC} ")" choice

    case $choice in
        1|01)
            apt-get update && apt-get install -y curl ca-certificates
            download_and_run "https://raw.githubusercontent.com/bear4f/cloudflare-ddns-manager/main/install-online.sh"
            ;;
        2|02)
            echo -e "${YELLOW}正在卸载 Cloudflare DDNS 并清理残留...${NC}"
            sudo systemctl disable --now cf-ddns.timer 2>/dev/null || true
            sudo systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
            sudo rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
            sudo rm -f /etc/systemd/system/cf-ddns-bot.service
            sudo systemctl daemon-reload
            sudo rm -f /usr/local/bin/ddns
            sudo rm -rf /usr/local/ddns
            sudo rm -f /var/log/cf_ddns.log
            echo -e "${GREEN}卸载完成！${NC}"
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
