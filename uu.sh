#!/bin/bash
# ==========================================================
#  Linai Enterprise VPS 多目录压缩工具
#  支持多目录 + 多系统 + 并行压缩 + 自动依赖安装
# ==========================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

DEFAULT_SAVE_DIR="$(pwd)"
CPU_CORES=$(nproc 2>/dev/null || echo 1)

echo -e "${BLUE}========================================${RESET}"
echo -e "${GREEN}      Linai Enterprise 压缩工具${RESET}"
echo -e "${BLUE}========================================${RESET}"
echo -e "CPU 核心数: ${YELLOW}${CPU_CORES}${RESET}"
echo

# =============================
# 多系统安装函数
# =============================
install_pkg() {
    pkg="$1"

    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    else
        echo -e "${RED}❌ 不支持的系统包管理器${RESET}"
        exit 1
    fi
}

check_cmd() {
    cmd="$1"

    if command -v "$cmd" >/dev/null 2>&1; then
        return
    fi

    echo -e "${YELLOW}安装 $cmd ...${RESET}"

    case "$cmd" in
        tar) install_pkg tar ;;
        zip) install_pkg zip ;;
        7z)
            if command -v apt >/dev/null 2>&1; then
                install_pkg p7zip-full
            else
                install_pkg p7zip
                install_pkg p7zip-plugins
            fi
            ;;
        xz) install_pkg xz ;;
        bzip2) install_pkg bzip2 ;;
        *) install_pkg "$cmd" ;;
    esac

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}❌ $cmd 安装失败${RESET}"
        exit 1
    fi
}

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
# 输入多目录
# =============================
echo
echo -e "${YELLOW}请输入要压缩的目录或文件路径（多个用空格分隔）:${RESET}"
read -a source_dirs

if [ ${#source_dirs[@]} -eq 0 ]; then
    echo -e "${RED}❌ 必须输入至少一个目录${RESET}"
    exit 1
fi

for dir in "${source_dirs[@]}"; do
    if [ ! -e "$dir" ]; then
        echo -e "${RED}❌ 路径不存在: $dir${RESET}"
        exit 1
    fi
done

# =============================
# 保存目录
# =============================
read -p "保存目录(默认 当前目录): " save_dir
save_dir=${save_dir:-$DEFAULT_SAVE_DIR}
mkdir -p "$save_dir"

read -p "输出文件名(不带后缀): " output_name
read -p "压缩级别(1-9 默认6): " level
read -p "排除目录(多个用空格 可留空): " -a exclude_dirs

level=${level:-6}
timestamp=$(date +%Y%m%d_%H%M%S)

start_time=$(date +%s)

# =============================
# 开始压缩
# =============================
case $format_choice in

1)
    check_cmd tar
    check_cmd gzip
    archive="${save_dir}/${output_name}_${timestamp}.tar.gz"

    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do
        exclude_args+=(--exclude="$ex")
    done

    tar "${exclude_args[@]}" -I "gzip -$level" -cvf "$archive" "${source_dirs[@]}"
    ;;

2)
    check_cmd tar
    check_cmd xz
    archive="${save_dir}/${output_name}_${timestamp}.tar.xz"

    tar -I "xz -T$CPU_CORES -$level" -cvf "$archive" "${source_dirs[@]}"
    ;;

3)
    check_cmd tar
    check_cmd bzip2
    archive="${save_dir}/${output_name}_${timestamp}.tar.bz2"

    tar -I "bzip2 -$level" -cvf "$archive" "${source_dirs[@]}"
    ;;

4)
    check_cmd zip
    archive="${save_dir}/${output_name}_${timestamp}.zip"
    zip -r -"$level" "$archive" "${source_dirs[@]}"
    ;;

5)
    check_cmd 7z
    archive="${save_dir}/${output_name}_${timestamp}.7z"
    7z a -mx="$level" "$archive" "${source_dirs[@]}"
    ;;

*)
    echo -e "${RED}❌ 无效选择${RESET}"
    exit 1
    ;;
esac

echo

# =============================
# 校验
# =============================
if [ ! -f "$archive" ]; then
    echo -e "${RED}❌ 压缩失败，文件未生成${RESET}"
    exit 1
fi

end_time=$(date +%s)
duration=$((end_time - start_time))

echo -e "${GREEN}✅ 压缩完成：${archive}${RESET}"
echo -e "${BLUE}文件大小：$(du -sh "$archive" | awk '{print $1}')${RESET}"
echo -e "${YELLOW}耗时：${duration} 秒${RESET}"
