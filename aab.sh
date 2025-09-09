#!/bin/bash
# 命令行美化工具（支持彩色菜单 + 还原）

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
CONFIG="$HOME/.bashrc"

menu() {
    clear
    echo "命令行美化工具"
    echo "------------------------"
    echo -e "1. \033[31mroot\033[0m localhost ~ #   (root 红色)"
    echo -e "2. root \033[32mlocalhost\033[0m ~ #   (localhost 绿色)"
    echo -e "3. root localhost \033[34m~\033[0m #   (~ 蓝色)"
    echo -e "4. \033[35mroot\033[0m \033[36mlocalhost\033[0m ~ # (紫+青)"
    echo -e "5. \033[33mroot\033[0m \033[31mlocalhost\033[0m ~ # (黄+红)"
    echo -e "6. \033[36mroot@localhost\033[0m ~ #  (整体青色)"
    echo -e "7. \033[32m[root@localhost]\033[34m ~\033[0m # (绿+蓝)"
    echo "------------------------"
    echo "8. 还原默认提示符"
    echo "0. 返回上一级选单"
    echo "------------------------"
    read -p "输入你的选择: " choice
}

set_ps1() {
    case $1 in
        1) PS1="\[\033[31m\]root\[\033[0m\] localhost ~ # " ;;
        2) PS1="root \[\033[32m\]localhost\[\033[0m\] ~ # " ;;
        3) PS1="root localhost \[\033[34m\]~\[\033[0m\] # " ;;
        4) PS1="\[\033[35m\]root\[\033[0m\] \[\033[36m\]localhost\[\033[0m\] ~ # " ;;
        5) PS1="\[\033[33m\]root\[\033[0m\] \[\033[31m\]localhost\[\033[0m\] ~ # " ;;
        6) PS1="\[\033[36m\]root@localhost\[\033[0m\] ~ # " ;;
        7) PS1="\[\033[32m\][root@localhost]\[\033[34m\] ~\[\033[0m\] # " ;;
        8) PS1="\\u@\\h:\\w\\$ " ;; # 还原默认
        *) return ;;
    esac

    # 写入配置
    sed -i '/^PS1=/d' "$CONFIG"
    echo "PS1='$PS1'" >> "$CONFIG"
    echo -e "${GREEN}变更完成。重新连接SSH后可查看变化！${RESET}"
    echo -e "${YELLOW}操作完成${RESET}"
    read -n 1 -s -r -p "按任意键继续..."
}

while true; do
    menu
    case $choice in
        0) break ;;
        [1-8]) set_ps1 $choice ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
