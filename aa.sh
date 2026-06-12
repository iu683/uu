#!/bin/bash

# ==========================================
# 颜色定义
# ==========================================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ==========================================
# 多代理与基础路径配置
# ==========================================
# 代理列表（包含空字符串代表直连）
GITHUB_PROXIES=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

BASE_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/VPS"

# ==========================================
# 工具函数
# ==========================================
# 暂停等待
pause() {
    read -r -p $'\033[32m按回车键返回菜单...\033[0m'
}

# 核心下载与无痕执行函数（支持多代理自动轮询容灾）
fetch_and_run() {
    local script_name="$1"
    local full_url="${BASE_URL}/${script_name}"
    local script_content=""
    local final_url=""
    
    # 遍历代理列表进行尝试
    for proxy in "${GITHUB_PROXIES[@]}"; do
        final_url="${proxy}${full_url}"
        
        # 打印当前尝试状态
        if [ -z "$proxy" ]; then
            echo
        else
            echo
        fi

        # 发起请求（限制 5 秒超时防止卡死）
        if script_content=$(curl -fsSL --connect-timeout 5 "$final_url") && [ -n "$script_content" ]; then
            # 使用 bash 执行脚本内容
            bash <(echo "$script_content")
            pause  # 执行完毕后在这里统一暂停
            return 0
        fi
    done
    
    # 所有节点尝试完毕均失败
    echo -e "${RED}错误：所有直连与代理节点均尝试失败，请检查网络设置。${RESET}"
    pause
    return 1
}

# ==========================================
# 主菜单函数
# ==========================================
menu() {
    while true; do
        clear
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN} ◈  系统监控管理菜单  ◈ ${RESET}"
        echo -e "${GREEN}========================${RESET}"
        echo -e "${GREEN} 1) 查看端口${RESET}"
        echo -e "${GREEN} 2) 释放端口${RESET}"
        echo -e "${GREEN} 3) 查看进程${RESET}"
        echo -e "${GREEN} 4) 删除进程${RESET}"
        echo -e "${GREEN} 5) 查看自启动服务${RESET}"
        echo -e "${GREEN} 6) 自启动服务管理${RESET}"
        echo -e "${GREEN} 7) 国家IP屏蔽${RESET}"
        echo -e "${GREEN} 8) 磁盘占用${RESET}"
        echo -e "${GREEN} 9) 安全扫描${RESET}"
        echo -e "${GREEN} 0) 退出${RESET}"
        echo -e "${GREEN}========================${RESET}"
        
        read -r -p $'\033[32m 请选择操作: \033[0m' choice
        case $choice in
            1)
                fetch_and_run "port.sh"
                ;;
            2)
                fetch_and_run "killport.sh"
                ;;
            3)
                fetch_and_run "psaux.sh"
                ;;
            4)
                fetch_and_run "killprocess.sh"
                ;;
            5)
                fetch_and_run "serviceos.sh"
                ;;
            6)
                fetch_and_run "killserviceos.sh"
                ;;
            7)
                fetch_and_run "GeoFirewallos.sh"
                ;;
            8)
                fetch_and_run "DHGL.sh"
                ;;
            9)
                fetch_and_run "Security.sh"
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入...${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ==========================================
# 启动菜单
# ==========================================
menu
