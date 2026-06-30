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

# 代理加速下载并执行函数（修复管道流占用 stdin 的 Bug）
run_with_proxy() {
    local raw_path="$1"
    shift
    local extra_args="$@"

    ensure_curl
    
    # 创建一个安全的临时脚本文件路径
    local tmp_script="/tmp/zelay_run_tmp_$$.sh"
    local success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local download_url="${proxy}https://raw.githubusercontent.com/${raw_path}"
        
        if [ -z "$proxy" ]; then
            echo -e "${CYAN}正在尝试直连下载...${RESET}"
        else
            echo -e "${CYAN}正在尝试通过代理下载: ${proxy}${RESET}"
        fi

        # 仅下载脚本，设置 15 秒连接超时
        curl -fsSL --connect-timeout 15 "$download_url" -o "$tmp_script"
        
        # 检查是否下载成功且文件不为空
        if [ $? -eq 0 ] && [ -s "$tmp_script" ]; then
            echo -e "${GREEN}下载成功，正在执行...${RESET}"
            echo -e "---------------------------------------"
            chmod +x "$tmp_script"
            
            # 在本地终端环境中正常执行（完美支持脚本内部的 y/n 交互提示）
            bash "$tmp_script" $extra_args
            
            success=true
            break # 成功执行后，跳出代理重试循环
        else
            echo -e "${YELLOW}当前节点下载失败，正在尝试下一个...${RESET}"
            [ -f "$tmp_script" ] && rm -f "$tmp_script"
        fi
    done

    # 彻底清理临时脚本文件
    [ -f "$tmp_script" ] && rm -f "$tmp_script"

    if [ "$success" = false ]; then
        echo -e "${RED}错误：所有 GitHub 代理节点均请求失败，请检查网络！${RESET}"
    fi
}

# 子菜单：服务运行管理
manage_services() {
    while true; do
        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}         ◈ Zelay 服务运行管理 ◈        ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${PURPLE} [面板服务 - zelay-manager]${RESET}"
        echo -e "${GREEN}  1. 启动 面板服务${RESET}"
        echo -e "${GREEN}  2. 停止 面板服务${RESET}"
        echo -e "${GREEN}  3. 重启 面板服务${RESET}"
        echo -e "${GREEN}  4. 查看 面板日志 (按 Ctrl+C 退出)${RESET}"
        echo -e "${GREEN}---------------------------------------${RESET}"
        echo -e "${CYAN} [Agent服务 - zelay-agent]${RESET}"
        echo -e "${CYAN}  5. 启动 Agent服务${RESET}"
        echo -e "${CYAN}  6. 停止 Agent服务${RESET}"
        echo -e "${CYAN}  7. 重启 Agent服务${RESET}"
        echo -e "${CYAN}  8. 查看 Agent日志 (按 Ctrl+C 退出)${RESET}"
        echo -e "${GREEN}---------------------------------------${RESET}"
        echo -e "${RED}  0. 返回主菜单${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        
        echo -e -n "${GREEN}请输入选项: ${RESET}"
        read svc_choice
        
        case $svc_choice in
            1) systemctl start zelay-manager && echo -e "${GREEN}面板服务已启动！${RESET}" ;;
            2) systemctl stop zelay-manager && echo -e "${YELLOW}面板服务已停止！${RESET}" ;;
            3) systemctl restart zelay-manager && echo -e "${GREEN}面板服务已重启！${RESET}" ;;
            4) journalctl -u zelay-manager -f ;;
            5) systemctl start zelay-agent && echo -e "${GREEN}Agent服务已启动！${RESET}" ;;
            6) systemctl stop zelay-agent && echo -e "${YELLOW}Agent服务已停止！${RESET}" ;;
            7) systemctl restart zelay-agent && echo -e "${GREEN}Agent服务已重启！${RESET}" ;;
            8) journalctl -u zelay-agent -f ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac
        
        if [ "$svc_choice" != "4" ] && [ "$svc_choice" != "8" ]; then
            echo -e -n "\n${GREEN}按任意键继续...${RESET}"
            read -n 1 -s -r
        fi
    done
}

# 主菜单循环
while true; do
    clear
    # 检测安装状态
    if [ -d "/etc/zelay-manager" ]; then
        STATUS="${YELLOW}[已安装]${NC}"
    else
        STATUS="${RED}[未安装]${NC}"
    fi
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}          ◈ Zelay 管理菜单 ◈          ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前状态: ${STATUS}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 1. 安装 Zelay 面板${RESET}"
    echo -e "${GREEN} 2. 更新 Zelay 面板${RESET}"
    echo -e "${GREEN} 3. 卸载 Zelay 面板${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${CYAN} 4. 更新 Zelay Agent (被控端)${RESET}"
    echo -e "${CYAN} 5. 卸载 Zelay Agent (被控端)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${YELLOW} 6. 面板/Agent 服务管理 (启动/停止/日志)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${RED} 0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}" 
    
    echo -e -n "${GREEN}请输入选项: ${RESET}"
    read choice
    
    case $choice in
        1)
            echo -e "${GREEN}===> 开始安装 Zelay 面板...${RESET}"
            echo -e -n "${CYAN}请输入面板访问端口 (web-port) [默认: 3000]: ${RESET}"
            read input_web_port
            WEB_PORT=${input_web_port:-3000}
            
            echo -e -n "${CYAN}请输入 Agent 通信端口 (agent-port) [默认: 3001]: ${RESET}"
            read input_agent_port
            AGENT_PORT=${input_agent_port:-3001}
            
            echo -e "${YELLOW}将使用以下配置进行安装:${RESET}"
            echo -e "${BLUE}面板端口: ${WEB_PORT}${RESET}"
            echo -e "${BLUE}通信端口: ${AGENT_PORT}${RESET}"
            echo -e "---------------------------------------"
            
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
                run_with_proxy "$MANAGER_RAW_PATH" uninstall
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
                run_with_proxy "$AGENT_RAW_PATH" uninstall
            else
                echo -e "${GREEN}已取消卸载。${RESET}"
            fi
            ;;
        6)
            manage_services
            continue
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请输入 0 到 6 之间的数字！${RESET}"
            ;;
    esac
    
    echo -e -n "\n${GREEN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
