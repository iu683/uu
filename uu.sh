#!/bin/bash
# 命令行美化工具（root@host:~# 格式，统一颜色）

CONFIG_FILE="$HOME/.bashrc"
[ -n "$ZSH_VERSION" ] && CONFIG_FILE="$HOME/.zshrc"

apply_prompt() {
    local ps1="$1"
    sed -i '/^PS1=/d' "$CONFIG_FILE"      # 删除旧配置
    echo "PS1=$ps1" >> "$CONFIG_FILE"     # 写入新配置
    eval "PS1=$ps1"                       # 立即生效
    echo -e "\033[32m✅ 已应用新命令行样式，重启终端可永久生效\033[0m"
    read -p "按回车返回菜单..."
}

while true; do
    echo "命令行美化工具"
    echo "------------------------"
    echo -e "1. \033[1;32mroot@\\h:~#\033[0m"
    echo -e "2. \033[1;33mroot@\\h:~#\033[0m"
    echo -e "3. \033[1;34mroot@\\h:~#\033[0m"
    echo -e "4. \033[1;35mroot@\\h:~#\033[0m"
    echo -e "5. \033[1;36mroot@\\h:~#\033[0m"
    echo -e "6. \033[1;37mroot@\\h:~#\033[0m"
    echo -e "7. root@\\h:~# (默认无颜色)"
    echo "------------------------"
    echo "0. 退出"
    echo "------------------------"
    read -e -p "输入你的选择: " choice

    case $choice in
      1) apply_prompt "'\[\033[1;32m\]\u@\h:\w#\[\033[0m\]'" ;;
      2) apply_prompt "'\[\033[1;33m\]\u@\h:\w#\[\033[0m\]'" ;;
      3) apply_prompt "'\[\033[1;34m\]\u@\h:\w#\[\033[0m\]'" ;;
      4) apply_prompt "'\[\033[1;35m\]\u@\h:\w#\[\033[0m\]'" ;;
      5) apply_prompt "'\[\033[1;36m\]\u@\h:\w#\[\033[0m\]'" ;;
      6) apply_prompt "'\[\033[1;37m\]\u@\h:\w#\[\033[0m\]'" ;;
      7) apply_prompt "'\u@\h:\w#'" ;;   # 默认无颜色
      0) echo "退出"; break ;;
      *) echo "无效选择"; read -p "按回车返回菜单..." ;;
    esac
done
