#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0;0m' # 无颜色

# GITHUB 代理列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 目标脚本的相对路径
RAW_PATH_MANAGER="ypq123456789/TrafficCop/main/trafficcop-manager.sh"
RAW_PATH_REMOVE="ypq123456789/TrafficCop/main/remove_traffic_limit.sh"

# 本地缓存文件名
LOCAL_MANAGER="trafficcop_manager_cache.sh"
LOCAL_REMOVE="remove_limit_cache.sh"

# 统一下载函数
download_script() {
    local raw_path="$1"
    local local_file="$2"
    
    # 优先检查本地是否存在已下载的脚本
    if [ -f "$local_file" ]; then
        echo
        return 0
    fi

    for proxy in "${GITHUB_PROXY[@]}"; do
        local download_url="${proxy}https://raw.githubusercontent.com/${raw_path}"
        echo
        
        # 使用 curl 下载，设置 10 秒超时
        if curl -fsSL --connect-timeout 10 "$download_url" -o "$local_file"; then
            echo
            return 0
        fi
        echo -e "${YELLOW}当前下载源超时或不可用，尝试下一个...${NC}"
    done

    echo -e "${RED}错误: 所有下载源均尝试失败，请检查网络后再试！${NC}"
    return 1
}

# 菜单主循环
while true; do
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}    ◈  TrafficCop 管理菜单  ◈     ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 TrafficCop${NC}"
    echo -e "${GREEN} 2. 解除网速限制${NC}"
    echo -e "${GREEN} 3. 卸载 TrafficCop${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}开始检查并准备安装 TrafficCop...${NC}\n"
            if download_script "$RAW_PATH_MANAGER" "$LOCAL_MANAGER"; then
                echo -e "${GREEN}开始执行安装逻辑...${NC}\n"
                bash "$LOCAL_MANAGER"
            else
                echo -e "${RED}安装中止。${NC}"
            fi
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}开始检查并准备解除网速限制...${NC}\n"
            if download_script "$RAW_PATH_REMOVE" "$LOCAL_REMOVE"; then
                echo -e "${GREEN}开始执行解除网速限制...${NC}\n"
                sudo bash "$LOCAL_REMOVE"
                echo -e "\n${GREEN}解除限制完成${NC}"
            else
                echo -e "${RED}解除网速限制操作中止。${NC}"
            fi
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        3)
            echo -e "\n${GREEN}开始卸载 TrafficCop...${NC}\n"
            sudo pkill -f traffic_monitor.sh
            sudo rm -rf /root/TrafficCop
            sudo tc qdisc del dev $(ip route | grep default | cut -d ' ' -f 5) root 2>/dev/null
            
            # 卸载时顺便清理本地缓存的脚本文件
            rm -f "$LOCAL_MANAGER" "$LOCAL_REMOVE"
            
            echo -e "\n${GREEN}卸载完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${GREEN}无效选项，请重新输入${NC}"
            sleep 2
            ;;
    esac
done
