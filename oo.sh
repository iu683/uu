#!/bin/bash
# ==========================================================
#   VPS 多目录压缩工具 (支持 Alpine/Debian/Ubuntu/CentOS)
# ==========================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

DEFAULT_SAVE_DIR="$(pwd)"
CPU_CORES=$(nproc 2>/dev/null || echo 1)

# =============================
# 多系统安装函数
# =============================
install_pkg() {
    pkg="$1"

    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y "$pkg"
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add "$pkg"
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
    if command -v "$cmd" >/dev/null 2>&1; then return; fi

    echo -e "${YELLOW}正在安装依赖 $cmd ...${RESET}"

    case "$cmd" in
        tar) install_pkg tar ;;
        zip) install_pkg zip ;;
        gzip) install_pkg gzip ;;
        xz) install_pkg xz ;;
        bzip2) install_pkg bzip2 ;;
        openssl) install_pkg openssl ;;
        7z)
            if command -v apt >/dev/null 2>&1; then
                install_pkg p7zip-full
            elif command -v apk >/dev/null 2>&1; then
                install_pkg p7zip
            else
                install_pkg p7zip
                install_pkg p7zip-plugins 2>/dev/null || true
            fi
            ;;
        *) install_pkg "$cmd" ;;
    esac

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}❌ $cmd 安装失败${RESET}"
        exit 1
    fi
}

# =============================
# 动态状态检测函数
# =============================
get_status() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    
    if [ $missing -eq 0 ]; then
        echo -e "${GREEN}[已安装]${RESET}"
    else
        echo -e "${YELLOW}[未安装]${RESET}"
    fi
}

# =============================
# 主循环菜单
# =============================
while true; do

clear
status_tgz=$(get_status tar gzip)
status_txz=$(get_status tar xz)
status_tbz=$(get_status tar bzip2)
status_zip=$(get_status zip)
status_7z=$(get_status 7z)

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}        ◈  多目录安全压缩工具  ◈         ${RESET}"
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}1) tar.gz (推荐)       ${status_tgz}${RESET}"
echo -e "${GREEN}2) tar.xz (高压缩)     ${status_txz}${RESET}"
echo -e "${GREEN}3) tar.bz2             ${status_tbz}${RESET}"
echo -e "${GREEN}4) zip                 ${status_zip}${RESET}"
echo -e "${GREEN}5) 7z                  ${status_7z}${RESET}"
echo -e "${GREEN}0) 退出${RESET}"
echo -e "${GREEN}========================================${RESET}"

read -p $'\033[32m请选择压缩格式: \033[0m' format_choice

if [[ "$format_choice" == "0" ]]; then
    exit 0
fi

echo -e "${YELLOW}请输入要压缩的目录或文件路径（多个用空格分隔）:${RESET}"
read -a source_dirs

if [ ${#source_dirs[@]} -eq 0 ]; then
    echo -e "${RED}❌ 必须输入至少一个目录${RESET}"
    read -p "回车继续..."
    continue
fi

for dir in "${source_dirs[@]}"; do
    if [ ! -e "$dir" ]; then
        echo -e "${RED}❌ 路径不存在: $dir${RESET}"
        read -p "回车继续..."
        continue 2
    fi
done

read -p "保存目录(默认 ${DEFAULT_SAVE_DIR}): " save_dir
save_dir=${save_dir:-$DEFAULT_SAVE_DIR}
mkdir -p "$save_dir"

read -p "输出文件名(不带后缀): " output_name
if [ -z "$output_name" ]; then
    echo -e "${RED}❌ 文件名不能为空${RESET}"
    read -p "回车继续..."
    continue
fi

read -p "压缩级别(1-9 默认6): " level
level=${level:-6}

read -p "排除目录/文件(多个用空格 可留空): " -a exclude_dirs

# --- 新增密码输入逻辑 ---
unset password
read -s -p "设置压缩密码 (留空则不加密): " password
echo
if [ -n "$password" ]; then
    read -s -p "请再次输入密码以确认: " password_confirm
    echo
    if [ "$password" != "$password_confirm" ]; then
        echo -e "${RED}❌ 两次输入的密码不一致！${RESET}"
        read -p "回车继续..."
        continue
    fi
fi

timestamp=$(date +%Y%m%d_%H%M%S)
start_time=$(date +%s)

# =============================
# 核心压缩与加密逻辑
# =============================
case $format_choice in

1)
    check_cmd tar; check_cmd gzip
    if [ -n "$password" ]; then check_cmd openssl; fi
    
    archive="${save_dir}/${output_name}_${timestamp}.tar.gz"
    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do exclude_args+=(--exclude="$ex"); done
    
    if [ -n "$password" ]; then
        # 加密模式：通过管道传递给 openssl 进行 aes-256-cbc 加密，后缀加上 .enc
        archive="${archive}.enc"
        tar "${exclude_args[@]}" -I "gzip -$level" -cvf - "${source_dirs[@]}" 2>/dev/null | \
        openssl aes-256-cbc -salt -pbkdf2 -k "$password" -out "$archive"
    else
        tar "${exclude_args[@]}" -I "gzip -$level" -cvf "$archive" "${source_dirs[@]}"
    fi
    ;;

2)
    check_cmd tar; check_cmd xz
    if [ -n "$password" ]; then check_cmd openssl; fi
    
    archive="${save_dir}/${output_name}_${timestamp}.tar.xz"
    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do exclude_args+=(--exclude="$ex"); done
    
    if [ -n "$password" ]; then
        archive="${archive}.enc"
        tar "${exclude_args[@]}" -I "xz -T$CPU_CORES -$level" -cvf - "${source_dirs[@]}" 2>/dev/null | \
        openssl aes-256-cbc -salt -pbkdf2 -k "$password" -out "$archive"
    else
        tar "${exclude_args[@]}" -I "xz -T$CPU_CORES -$level" -cvf "$archive" "${source_dirs[@]}"
    fi
    ;;

3)
    check_cmd tar; check_cmd bzip2
    if [ -n "$password" ]; then check_cmd openssl; fi
    
    archive="${save_dir}/${output_name}_${timestamp}.tar.bz2"
    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do exclude_args+=(--exclude="$ex"); done
    
    if [ -n "$password" ]; then
        archive="${archive}.enc"
        tar "${exclude_args[@]}" -I "bzip2 -$level" -cvf - "${source_dirs[@]}" 2>/dev/null | \
        openssl aes-256-cbc -salt -pbkdf2 -k "$password" -out "$archive"
    else
        tar "${exclude_args[@]}" -I "bzip2 -$level" -cvf "$archive" "${source_dirs[@]}"
    fi
    ;;

4)
    check_cmd zip
    archive="${save_dir}/${output_name}_${timestamp}.zip"
    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do exclude_args+=("-x" "$ex/*" "-x" "$ex"); done
    
    if [ -n "$password" ]; then
        # zip 使用 -P 参数传入密码
        zip -r -"$level" -P "$password" "$archive" "${source_dirs[@]}" "${exclude_args[@]}"
    else
        zip -r -"$level" "$archive" "${source_dirs[@]}" "${exclude_args[@]}"
    fi
    ;;

5)
    check_cmd 7z
    archive="${save_dir}/${output_name}_${timestamp}.7z"
    exclude_args=()
    for ex in "${exclude_dirs[@]}"; do exclude_args+=("-xr!$ex"); done
    
    if [ -n "$password" ]; then
        # 7z 使用 -p 参数，并附带 -mhe=on 加密文件名（更安全）
        7z a -mx="$level" -p"$password" -mhe=on "${exclude_args[@]}" "$archive" "${source_dirs[@]}"
    else
        7z a -mx="$level" "${exclude_args[@]}" "$archive" "${source_dirs[@]}"
    fi
    ;;

*)
    echo -e "${RED}❌ 无效选择${RESET}"
    read -p "回车继续..."
    continue
    ;;
esac

echo

# =============================
# 结果输出
# =============================
if [ ! -f "$archive" ]; then
    echo -e "${RED}❌ 压缩/加密失败${RESET}"
else
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo -e "${GREEN}✅ 任务完成：${archive}${RESET}"
    if [ -n "$password" ]; then
        echo -e "${RED}🔒 状态：已启用密码保护${RESET}"
    fi
    echo -e "${BLUE}文件大小：$(du -sh "$archive" | awk '{print $1}')${RESET}"
    echo -e "${YELLOW}耗时：${duration} 秒${RESET}"
fi

read -p $'\033[32m回车返回主菜单...\033[0m'
done
