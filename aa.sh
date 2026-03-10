#!/usr/bin/env bash

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

################################
# 下载工具检测
################################
get_cmd() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget -qO-"
    else
        echo -e "${RED}未找到 curl 或 wget${RESET}"
        exit 1
    fi
}
FETCH=$(get_cmd)

################################
# 支持参数传递
################################
run_remote() {
    url=$1
    shift
    bash <($FETCH "$url") "$@"
}

pause() {
    read -p $'\033[32m按回车键继续...\033[0m'
}

################################
# 菜单
################################
menu() {
    clear
    echo -e "${GREEN}===== Zelay Realm 转发面板管理 =====${RESET}"
    echo -e "${GREEN}1) 安装 Zelay 面板${RESET}"
    echo -e "${GREEN}2) 更新 Zelay 面板${RESET}"
    echo -e "${GREEN}3) 卸载 Zelay 面板${RESET}"
    echo -e "${GREEN}4) 更新 Zelay 节点${RESET}"
    echo -e "${GREEN}5) 卸载 Zelay 节点${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
}

################################
# 主循环
################################
while true; do
    menu
    read -p $'\033[32m请选择操作: \033[0m' choice

    case $choice in
        1)

            read -p $'\033[32m请输入 Web 面板端口 (默认5755): \033[0m' web_port
            web_port=${web_port:-5755}

            read -p $'\033[32m请输入 Agent 端口 (默认5756): \033[0m' agent_port
            agent_port=${agent_port:-5756}

            run_remote \
              "https://raw.githubusercontent.com/enp6/Zelay/main/zelay_manager.sh" \
              web-port=$web_port agent-port=$agent_port

            pause
            ;;
        2)
            run_remote \
              "https://raw.githubusercontent.com/enp6/Zelay/main/zelay_manager.sh" \
              update
            pause
            ;;
        3)
            run_remote \
              "https://raw.githubusercontent.com/enp6/Zelay/main/zelay_manager.sh" \
              uninstall
            pause
            ;;
         4)
            run_remote \
              "https://raw.githubusercontent.com/enp6/Zelay/main/zelay_agent.sh" \
              update
            pause
            ;;
        5)
            run_remote \
              "https://raw.githubusercontent.com/enp6/Zelay/main/zelay_agent.sh" \
              uninstall
            pause
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            sleep 1
            ;;
    esac
done
