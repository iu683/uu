#!/bin/bash
# =================================================
# VPS 一键解压工具 Pro（多系统自动适配）
# 支持 Debian / Ubuntu / CentOS / Rocky / Alma / Fedora / Arch
# =================================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}====== VPS 解压工具======${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

# ===============================
# 自动识别包管理器
# ===============================
detect_pm() {
    if command -v apt-get &>/dev/null; then
        PM="apt-get"
        INSTALL="apt-get install -y"
        UPDATE="apt-get update -y"
    elif command -v dnf &>/dev/null; then
        PM="dnf"
        INSTALL="dnf install -y"
        UPDATE="dnf makecache"
    elif command -v yum &>/dev/null; then
        PM="yum"
        INSTALL="yum install -y"
        UPDATE="yum makecache"
    elif command -v pacman &>/dev/null; then
        PM="pacman"
        INSTALL="pacman -Sy --noconfirm"
        UPDATE="pacman -Sy"
    else
        echo -e "${RED}❌ 不支持的系统，未找到包管理器${RESET}"
        exit 1
    fi
}

install_pkg() {
    PKG=$1
    if ! command -v "$PKG" &>/dev/null; then
        echo -e "${YELLOW}$PKG 未安装，正在安装...${RESET}"
        $UPDATE
        $INSTALL "$PKG"
    fi
}

detect_pm

read -rp $'\033[32m请输入要解压的文件路径：\033[0m' FILE

if [[ ! -f "$FILE" ]]; then
    echo -e "${RED}文件不存在！退出${RESET}"
    exit 1
fi

read -rp "请输入解压到的目标目录（默认/root）： " DEST
DEST=${DEST:-$(pwd)}

mkdir -p "$DEST"

FILENAME=$(basename "$FILE")
LOWER_NAME=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')

echo -e "${BLUE}正在识别文件类型...${RESET}"

case "$LOWER_NAME" in

    *.zip)
        install_pkg unzip
        echo -e "${GREEN}正在解压 ZIP 文件...${RESET}"
        unzip -o "$FILE" -d "$DEST"
        ;;

    *.tar)
        echo -e "${GREEN}正在解压 TAR 文件...${RESET}"
        tar -xvf "$FILE" -C "$DEST"
        ;;

    *.tar.gz|*.tgz)
        echo -e "${GREEN}正在解压 TAR.GZ 文件...${RESET}"
        tar -xvzf "$FILE" -C "$DEST"
        ;;

    *.tar.bz2)
        echo -e "${GREEN}正在解压 TAR.BZ2 文件...${RESET}"
        tar -xvjf "$FILE" -C "$DEST"
        ;;

    *.tar.xz)
        echo -e "${GREEN}正在解压 TAR.XZ 文件...${RESET}"
        tar -xvJf "$FILE" -C "$DEST"
        ;;

    *.rar)
        install_pkg unrar
        echo -e "${GREEN}正在解压 RAR 文件...${RESET}"
        unrar x -o+ "$FILE" "$DEST"
        ;;

    *.7z)
        install_pkg p7zip
        install_pkg p7zip-full 2>/dev/null || true
        echo -e "${GREEN}正在解压 7Z 文件...${RESET}"
        7z x "$FILE" -o"$DEST" -y
        ;;

    *)
        echo -e "${RED}❌ 不支持的压缩格式: $FILENAME${RESET}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 解压完成！文件已放到: $DEST${RESET}"
