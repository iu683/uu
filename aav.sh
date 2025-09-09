#!/bin/bash
# 命令行美化工具

CONFIG_FILE="$HOME/.bashrc"
[ -n "$ZSH_VERSION" ] && CONFIG_FILE="$HOME/.zshrc"

apply_prompt() {
    local ps1="$1"
    # 删除旧的配置
    sed -i '/^PS1=/d' "$CONFIG_FILE"
    # 写入新配置
    echo "$ps1" >> "$CONFIG_FILE"
    # 立即生效
    eval "$ps1"
    echo -e "\033[32m✅ 已应用新命令行样式，重启终端可永久生效\033[0m"
}

while true; do
    clear
    echo "命令行美化工具"
    echo "------------------------"
    echo -e "1. \033[1;32mroot \033[1;34mlocalhost \033[1;31m~ \033[0m#"
    echo -e "2. \033[1;35mroot \033[1;36mlocalhost \033[1;33m~ \033[0m#"
    echo -e "3. \033[1;31mroot \033[1;32mlocalhost \033[1;34m~ \033[0m#"
    echo -e "4. \033[1;36mroot \033[1;33mlocalhost \033[1;37m~ \033[0m#"
    echo -e "5. \033[1;37mroot \033[1;31mlocalhost \033[1;32m~ \033[0m#"
    echo -e "6. \033[1;33mroot \033[1;34mlocalhost \033[1;35m~ \033[0m#"
    echo -e "7. root localhost ~ # (默认)"
    echo "------------------------"
    echo "0. 退出"
    echo "------------------------"
    read -e -p "输入你的选择: " choice

    case $choice in
      1) apply_prompt "PS1='\\[\\033[1;32m\\]\\u\\[\\033[0m\\]@\\[\\033[1;34m\\]\\h\\[\\033[0m\\] \\[\\033[1;31m\\]\\w\\[\\033[0m\\] # '" ;;
      2) apply_prompt "PS1='\\[\\033[1;35m\\]\\u\\[\\033[0m\\]@\\[\\033[1;36m\\]\\h\\[\\033[0m\\] \\[\\033[1;33m\\]\\w\\[\\033[0m\\] # '" ;;
      3) apply_prompt "PS1='\\[\\033[1;31m\\]\\u\\[\\033[0m\\]@\\[\\033[1;32m\\]\\h\\[\\033[0m\\] \\[\\033[1;34m\\]\\w\\[\\033[0m\\] # '" ;;
      4) apply_prompt "PS1='\\[\\033[1;36m\\]\\u\\[\\033[0m\\]@\\[\\033[1;33m\\]\\h\\[\\033[0m\\] \\[\\033[1;37m\\]\\w\\[\\033[0m\\] # '" ;;
      5) apply_prompt "PS1='\\[\\033[1;37m\\]\\u\\[\\033[0m\\]@\\[\\033[1;31m\\]\\h\\[\\033[0m\\] \\[\\033[1;32m\\]\\w\\[\\033[0m\\] # '" ;;
      6) apply_prompt "PS1='\\[\\033[1;33m\\]\\u\\[\\033[0m\\]@\\[\\033[1;34m\\]\\h\\[\\033[0m\\] \\[\\033[1;35m\\]\\w\\[\\033[0m\\] # '" ;;
      7) apply_prompt "PS1='\\u@\\h \\w # '" ;;
      0) echo "退出"; break ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
done
