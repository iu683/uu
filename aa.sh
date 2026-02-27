#!/bin/bash
# safe_delete_sudo_v2.sh - 安全一键删除文件/目录脚本（增强版）

# 颜色提示
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}请输入要删除的文件或目录（支持通配符，例如 *.log）:${RESET}"
read target

# 检查输入是否为空
if [[ -z "$target" ]]; then
    echo -e "${RED}未输入文件或目录，退出。${RESET}"
    exit 1
fi

# 查找匹配的文件/目录
files=$(sudo ls -1 $target 2>/dev/null)

if [[ -z "$files" ]]; then
    echo -e "${RED}没有找到匹配的文件或目录，退出。${RESET}"
    exit 1
fi

# 显示待删除文件列表
echo -e "${YELLOW}以下文件/目录将被删除:${RESET}"
echo "$files"

# 确认操作
echo -e "${RED}确定要删除以上文件/目录吗？此操作不可恢复！(y/N):${RESET}"
read confirm

if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    # 遍历每个文件/目录安全删除
    while IFS= read -r f; do
        sudo rm -rf "$f"
    done <<< "$files"
    echo -e "${GREEN}删除完成！${RESET}"
else
    echo -e "${YELLOW}已取消删除。${RESET}"
fi
