#!/bin/bash
# ==========================================
# VPS 多格式压缩工具
# 支持 tar.gz / tar.xz / tar.bz2 / zip / 7z
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

# 必须 root（可选）
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}⚠️ 建议使用 root 运行（某些目录可能无权限）${RESET}"
fi

# =============================
# 依赖检测
# =============================
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}❌ 未安装 $1，正在尝试安装...${RESET}"
        apt update && apt install -y "$1" || yum install -y "$1"
    fi
}

# =============================
# 选择格式
# =============================
echo -e "${BLUE}============================${RESET}"
echo -e "${GREEN}      VPS 压缩工具${RESET}"
echo -e "${BLUE}============================${RESET}"

echo "1) tar.gz   (通用推荐)"
echo "2) tar.xz   (更高压缩率)"
echo "3) tar.bz2"
echo "4) zip"
echo "5) 7z"
echo

read -p "请选择压缩格式: " format_choice
read -p "请输入要压缩的目录或文件路径: " target
read -p "请输入输出文件名(不带后缀): " output_name
read -p "压缩级别(1-9，默认6): " level
read -p "是否排除某目录？(留空跳过): " exclude_path

timestamp=$(date +%Y%m%d_%H%M%S)

if [ -z "$level" ]; then
    level=6
fi

# =============================
# 开始压缩
# =============================
case $format_choice in

1)
    check_cmd tar
    archive="${output_name}_${timestamp}.tar.gz"
    echo -e "${GREEN}正在创建 tar.gz 压缩包...${RESET}"
    if [ -n "$exclude_path" ]; then
        tar --exclude="$exclude_path" -czvf "$archive" "$target"
    else
        tar -czvf "$archive" "$target"
    fi
    ;;

2)
    check_cmd tar
    archive="${output_name}_${timestamp}.tar.xz"
    echo -e "${GREEN}正在创建 tar.xz 压缩包...${RESET}"
    tar -I "xz -$level" -cvf "$archive" "$target"
    ;;

3)
    check_cmd tar
    archive="${output_name}_${timestamp}.tar.bz2"
    echo -e "${GREEN}正在创建 tar.bz2 压缩包...${RESET}"
    tar -I "bzip2 -$level" -cvf "$archive" "$target"
    ;;

4)
    check_cmd zip
    archive="${output_name}_${timestamp}.zip"
    echo -e "${GREEN}正在创建 zip 压缩包...${RESET}"
    zip -r -"$level" "$archive" "$target"
    ;;

5)
    check_cmd 7z
    archive="${output_name}_${timestamp}.7z"
    echo -e "${GREEN}正在创建 7z 压缩包...${RESET}"
    7z a -mx="$level" "$archive" "$target"
    ;;

*)
    echo -e "${RED}❌ 无效选择${RESET}"
    exit 1
    ;;

esac

echo
echo -e "${GREEN}✅ 压缩完成：${archive}${RESET}"
echo -e "${BLUE}文件大小：$(du -sh "$archive" | awk '{print $1}')${RESET}"
