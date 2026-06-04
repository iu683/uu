#!/bin/sh
# =================================================
# VPS 一键解压工具 Pro（全系统完美兼容版）
# 支持 Debian / Ubuntu / CentOS / Rocky / Alma / Fedora / Arch / Alpine
# =================================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}====== VPS 解压工具 ======${RESET}"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

# ===============================
# 自动识别包管理器 (已加入 Alpine 支持)
# ===============================
detect_pm() {
    if command -v apk >/dev/null 2>&1; then
        PM="apk"
        INSTALL="apk add --no-cache"
        UPDATE="true" # Alpine 安装时带 --no-cache 不需要单独 update
    elif command -v apt-get >/dev/null 2>&1; then
        PM="apt-get"
        INSTALL="apt-get install -y"
        UPDATE="apt-get update -y"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
        INSTALL="dnf install -y"
        UPDATE="dnf makecache"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
        INSTALL="yum install -y"
        UPDATE="yum makecache"
    elif command -v pacman >/dev/null 2>&1; then
        PM="pacman"
        INSTALL="pacman -Sy --noconfirm"
        UPDATE="pacman -Sy"
    else
        echo -e "${RED}❌ 不支持的系统，未找到包管理器${RESET}"
        exit 1
    fi
}

# 智能安装函数
install_pkg() {
    local cmd_name="$1"
    local pkg_name="$2"
    
    # 如果没指定包名，默认包名和命令名一致
    [ -z "$pkg_name" ] && pkg_name="$cmd_name"

    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚙️ $cmd_name 未安装，正在通过 $PM 安装包 $pkg_name ...${RESET}"
        $UPDATE >/dev/null 2>&1 || true
        $INSTALL "$pkg_name"
    fi
}

detect_pm

# 交互输入文件路径
echo -ne "${GREEN}请输入要解压的文件路径：${RESET}"
read -r FILE

# 修复：改用 POSIX 标准语法检测文件是否存在，防止 Alpine 下 sh 环境闪退
if [ ! -f "$FILE" ]; then
    echo -e "${RED}❌ 文件不存在！退出${RESET}"
    exit 1
fi

# 交互输入目标路径
echo -ne "请输入解压到的目标目录（默认当前目录 [ $(pwd) ]）："
read -r DEST
DEST=${DEST:-$(pwd)}

mkdir -p "$DEST"

FILENAME=$(basename "$FILE")
LOWER_NAME=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')

echo -e "${BLUE}🔍 正在识别文件类型...${RESET}"

case "$LOWER_NAME" in

    *.zip)
        install_pkg unzip
        echo -e "${GREEN}📦 正在解压 ZIP 文件...${RESET}"
        unzip -o "$FILE" -d "$DEST"
        ;;

    *.tar)
        echo -e "${GREEN}📦 正在解压 TAR 文件...${RESET}"
        tar -xvf "$FILE" -C "$DEST"
        ;;

    *.tar.gz|*.tgz)
        echo -e "${GREEN}📦 正在解压 TAR.GZ 文件...${RESET}"
        tar -xvzf "$FILE" -C "$DEST"
        ;;

    *.tar.bz2)
        echo -e "${GREEN}📦 正在解压 TAR.BZ2 文件...${RESET}"
        tar -xvjf "$FILE" -C "$DEST"
        ;;

    *.tar.xz)
        echo -e "${GREEN}📦 正在解压 TAR.XZ 文件...${RESET}"
        tar -xvJf "$FILE" -C "$DEST"
        ;;

    *.rar)
        install_pkg unrar
        echo -e "${GREEN}📦 正在解压 RAR 文件...${RESET}"
        unrar x -o+ "$FILE" "$DEST"
        ;;

    *.7z)
        # 针对不同包管理器的 7z 命名规则做智能转换
        if [ "$PM" = "apk" ]; then
            install_pkg 7z p7zip
        elif [ "$PM" = "apt-get" ]; then
            install_pkg 7z p7zip-full
        else
            install_pkg 7z p7zip
        fi
        echo -e "${GREEN}📦 正在解压 7Z 文件...${RESET}"
        7z x "$FILE" -o"$DEST" -y
        ;;

    *)
        echo -e "${RED}❌ 不支持的压缩格式: $FILENAME${RESET}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 解压完成！文件已放到: $DEST${RESET}"
