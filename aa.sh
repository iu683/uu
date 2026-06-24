#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本！${RESET}"
    exit 1
fi

# GitHub 相对路径
MANAGER_RAW_PATH="enp6/Zelay/main/zelay_manager.sh"
AGENT_RAW_PATH="enp6/Zelay/main/zelay_agent.sh"

# GitHub 代理节点列表（第一个为空代表直连）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 检查并安装 curl 的函数
ensure_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在自动安装...${RESET}"
        if command -v apt &> /dev/null; then
            apt update && apt install curl -y
        elif command -v yum &> /dev/null; then
            yum install curl -y
        fi
    fi
}

# 代理加速执行函数
# 参数 1: 脚本相对路径 (MANAGER_RAW_PATH 或 AGENT_RAW_PATH)
# 参数 2: 后续要跟的附加参数 (例如 update, --uninstall, 或者端口参数)
run_with_proxy() {
    local raw_path="$1"
    shift
    local extra_args="$@"

    ensure_curl
    
    local success=false
    # 遍历代理列表进行下载并直接执行
    for proxy in "${GITHUB_PROXY[@]}"; do
        local download_url="${proxy}https://raw.githubusercontent.com/${raw_path}"
        
        if [ -z "$proxy" ]; then
            echo -e "${CYAN}正在尝试直连远程...${RESET}"
        else
            echo -e "${CYAN}正在尝试通过代理远程: ${proxy}${RESET}"
        fi

        # 尝试通过 bash 执行远程脚本，设置 15 秒连接超时
        # 如果远程脚本执行成功，它的退出状态码通常是它内部逻辑的状态，这里主要捕捉网络错误
        if curl -fsSL --connect-timeout 15 "$download_url" | bash -s -- $extra_args; then
            success=true
            break # 成功执行，跳出循环
        else
            echo -e "${YELLOW}当前节点连接或执行失败，正在尝试下一个...${RESET}"
        fi
    done

    # 如果所有节点都失败了
    if [ "$success" = false ]; then
        echo -e "${RED}错误：所有 GitHub 代理节点均请求失败，请检查网络！${RESET}"
    fi
}

# 主菜单循环
while true; do
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}      ◈   Zelay 管理菜单   ◈          ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 1. 安装 Zelay 面板${RESET}"
    echo -e "${GREEN} 2. 更新 Zelay 面板${RESET}"
    echo -e "${GREEN} 3. 卸载 Zelay 面板${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${CYAN} 4. 更新 Zelay Agent (被控端)${RESET}"
    echo -e "${CYAN} 5. 卸载 Zelay Agent (被控端)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${RED} 0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}" 
    
    echo -e -n "${GREEN}请输入选项 [0-5]: ${RESET}"
    read choice
    
    case $choice in
        1)
            echo -e "${GREEN}===> 开始安装 Zelay 面板...${RESET}"
            
            # 交互式输入 Web 端口
            echo -e -n "${CYAN}请输入面板访问端口 (web-port) [默认: 3000]: ${RESET}"
            read input_web_port
            WEB_PORT=${input_web_port:-3000}
            
            # 交互式输入 Agent 端口
            echo -e -n "${CYAN}请输入 Agent 通信端口 (agent-port) [默认: 3001]: ${RESET}"
            read input_agent_port
            AGENT_PORT=${input_agent_port:-3001}
            
            echo -e "${YELLOW}将使用以下配置进行安装:${RESET}"
            echo -e "${BLUE}面板端口: ${WEB_PORT}${RESET}"
            echo -e "${BLUE}通信端口: ${AGENT_PORT}${RESET}"
            echo -e "---------------------------------------"
            
            # 传入解析后的端口参数
            run_with_proxy "$MANAGER_RAW_PATH" web-port="$WEB_PORT" agent-port="$AGENT_PORT"
            ;;
        2)
            echo -e "${YELLOW}===> 开始更新 Zelay 面板...${RESET}"
            run_with_proxy "$MANAGER_RAW_PATH" update
            ;;
        3)
            echo -e "${RED}===> 警告：即将卸载 Zelay 面板！${RESET}"
            echo -e -n "${YELLOW}确定要继续吗？(y/n): ${RESET}"
            read confirm
            if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
                run_with_proxy "$MANAGER_RAW_PATH" --uninstall
            else
                echo -e "${GREEN}已取消卸载。${RESET}"
            fi
            ;;
        4)
            echo -e "${YELLOW}===> 开始更新 Zelay Agent...${RESET}"
            run_with_proxy "$AGENT_RAW_PATH" update
            ;;
        5)
            echo -e "${RED}===> 警告：即将卸载 Zelay Agent！${RESET}"
            echo -e -n "${YELLOW}确定要继续吗？(y/n): ${RESET}"
            read confirm
            if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
                run_with_proxy "$AGENT_RAW_PATH" --uninstall
            else
                echo -e "${GREEN}已取消卸载。${RESET}"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请输入 0 到 5 之间的数字！${RESET}"
            ;;
    esac
    
    echo -e -n "\n${GREEN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
