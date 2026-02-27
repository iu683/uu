#!/bin/bash
# safe_delete_sudo_v4.sh - 安全删除文件/目录（支持多文件/多目录）

# 颜色提示
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}请输入要删除的文件或目录路径（支持空格分隔、通配符，例如 *.log dir1 file2）:${RESET}"
read -r targets

# 检查输入是否为空
if [[ -z "$targets" ]]; then
    echo -e "${RED}未输入文件或目录，退出。${RESET}"
    exit 1
fi

# 打开 nullglob 支持通配符
shopt -s nullglob
files=()
for t in $targets; do
    expanded=($t)
    files+=("${expanded[@]}")
done

# 检查是否找到匹配文件
if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${RED}没有找到匹配的文件/目录，退出。${RESET}"
    exit 1
fi

# 显示待删除文件列表
echo -e "${YELLOW}以下文件/目录将被删除:${RESET}"
for f in "${files[@]}"; do
    echo "$f"
done

# 二次确认
echo -e "${RED}确定要删除以上文件/目录吗？此操作不可恢复！(y/N):${RESET}"
read -r confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${YELLOW}已取消删除。${RESET}"
    exit 0
fi

echo -e "${YELLOW}正在删除文件/目录...${RESET}"

# 遍历删除
for f in "${files[@]}"; do
    if [[ ! -e "$f" ]]; then
        echo -e "${RED}不存在，跳过：$f${RESET}"
        continue
    fi

    # 检查 immutable 属性
    if sudo lsattr "$f" 2>/dev/null | grep -q 'i'; then
        echo -e "${RED}检测到不可变属性 (immutable) 文件/目录：$f${RESET}"
        echo -e "${YELLOW}尝试移除 immutable 属性...${RESET}"
        sudo chattr -i "$f" 2>/tmp/delete_err.log
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}无法移除 immutable 属性，跳过删除：$f${RESET}"
            cat /tmp/delete_err.log
            continue
        fi
    fi

    # 执行删除
    sudo rm -rf "$f" 2>/tmp/delete_err.log
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}删除成功：$f${RESET}"
    else
        echo -e "${RED}删除失败：$f${RESET}"
        cat /tmp/delete_err.log
    fi
done

echo -e "${GREEN}操作完成！${RESET}"
