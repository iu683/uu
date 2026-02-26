#!/bin/bash
# =================================================
# VPS 一键解压工具 Pro（无 file 依赖 + 自动安装工具）
# =================================================

set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}====== VPS 一键解压工具 Pro ======${RESET}"

# 必须 root（避免安装时报错）
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

read -rp "请输入要解压的文件路径（例如 /opt/test.tar.gz）： " FILE

if [[ ! -f "$FILE" ]]; then
    echo -e "${RED}文件不存在！退出${RESET}"
    exit 1
fi

read -rp "请输入解压到的目标目录（留空为当前目录）： " DEST
DEST=${DEST:-$(pwd)}

mkdir -p "$DEST"

# 获取文件名（小写）
FILENAME=$(basename "$FILE")
LOWER_NAME=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')

install_pkg() {
    PKG=$1
    if ! command -v "$PKG" &>/dev/null; then
        echo -e "${YELLOW}$PKG 未安装，正在安装...${RESET}"
        apt-get update -y
        apt-get install -y "$PKG"
    fi
}

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
        install_pkg 7z
        echo -e "${GREEN}正在解压 7Z 文件...${RESET}"
        7z x "$FILE" -o"$DEST" -y
        ;;

    *)
        echo -e "${RED}❌ 不支持的压缩格式: $FILENAME${RESET}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 解压完成！文件已放到: $DEST${RESET}"
