#!/bin/bash
# ==========================================
# VPS 多格式压缩工具（强制输入目录）
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

DEFAULT_SAVE_DIR="$(pwd)"

echo -e "${BLUE}============================${RESET}"
echo -e "${GREEN}      VPS 压缩工具${RESET}"
echo -e "${BLUE}============================${RESET}"

# =============================
# 选择格式
# =============================
echo -e "${GREEN}1) tar.gz (推荐)${RESET}"
echo -e "${GREEN}2) tar.xz (高压缩)${RESET}"
echo -e "${GREEN}3) tar.bz2${RESET}"
echo -e "${GREEN}4) zip${RESET}"
echo -e "${GREEN}5) 7z${RESET}"

read -p $'\033[32m请选择压缩格式: \033[0m' format_choice

# =============================
# 必须输入压缩目录
# =============================
read -p "请输入要压缩的目录或文件路径: " source_dir

if [ -z "$source_dir" ]; then
    echo -e "${RED}❌ 必须输入压缩目录${RESET}"
    exit 1
fi

if [ ! -e "$source_dir" ]; then
    echo -e "${RED}❌ 目录不存在${RESET}"
    exit 1
fi

# =============================
# 保存目录（可默认）
# =============================
read -p "请输入压缩文件保存目录(默认 当前目录): " save_dir
save_dir=${save_dir:-$DEFAULT_SAVE_DIR}
mkdir -p "$save_dir"

read -p "请输入输出文件名(不带后缀): " output_name
read -p "压缩级别(1-9 默认6): " level
read -p "排除目录(可留空): " exclude_path

level=${level:-6}
timestamp=$(date +%Y%m%d_%H%M%S)

# =============================
# 依赖检测
# =============================
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${YELLOW}安装 $1 ...${RESET}"
        apt update && apt install -y "$1" 2>/dev/null || yum install -y "$1"
    fi
}

# =============================
# 开始压缩
# =============================
case $format_choice in

1)
    check_cmd tar
    archive="${save_dir}/${output_name}_${timestamp}.tar.gz"
    if [ -n "$exclude_path" ]; then
        tar --exclude="$exclude_path" -czvf "$archive" "$source_dir"
    else
        tar -czvf "$archive" "$source_dir"
    fi
    ;;

2)
    check_cmd tar
    archive="${save_dir}/${output_name}_${timestamp}.tar.xz"
    tar -I "xz -$level" -cvf "$archive" "$source_dir"
    ;;

3)
    check_cmd tar
    archive="${save_dir}/${output_name}_${timestamp}.tar.bz2"
    tar -I "bzip2 -$level" -cvf "$archive" "$source_dir"
    ;;

4)
    check_cmd zip
    archive="${save_dir}/${output_name}_${timestamp}.zip"
    cd "$(dirname "$source_dir")"
    zip -r -"$level" "$archive" "$(basename "$source_dir")"
    ;;

5)
    check_cmd 7z
    archive="${save_dir}/${output_name}_${timestamp}.7z"
    7z a -mx="$level" "$archive" "$source_dir"
    ;;

*)
    echo -e "${RED}❌ 无效选择${RESET}"
    exit 1
    ;;

esac

echo
echo -e "${GREEN}✅ 压缩完成：${archive}${RESET}"
echo -e "${BLUE}文件大小：$(du -sh "$archive" | awk '{print $1}')${RESET}"
