#!/bin/bash
# =================================================
# VPS 一键解压工具（自动判断类型 + 保留原始目录结构）
# 支持 zip / tar / tar.gz / tgz / tar.bz2 等
# =================================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${GREEN}====== VPS 一键解压工具 ======${RESET}"

# 1. 输入压缩文件路径
read -rp "请输入要解压的文件路径（绝对或相对路径）： " FILE
if [[ ! -f "$FILE" ]]; then
    echo -e "${RED}文件不存在！退出${RESET}"
    exit 1
fi

# 2. 输入目标解压目录
read -rp "请输入解压到的目标目录（留空表示当前目录）： " DEST
DEST=${DEST:-$(pwd)}

# 创建目录（如果不存在）
mkdir -p "$DEST"

# 3. 判断文件类型并解压
# 使用 file 命令更智能判断
TYPE=$(file -b --mime-type "$FILE")

case "$TYPE" in
    application/zip)
        if ! command -v unzip &>/dev/null; then
            echo -e "${YELLOW}unzip 未安装，尝试安装...${RESET}"
            apt-get update -y && apt-get install -y unzip
        fi
        echo -e "${GREEN}正在解压 ZIP 文件...${RESET}"
        unzip -o "$FILE" -d "$DEST"
        ;;
    application/x-tar)
        echo -e "${GREEN}正在解压 TAR 文件...${RESET}"
        tar -xvf "$FILE" -C "$DEST"
        ;;
    application/gzip)
        echo -e "${GREEN}正在解压 TAR.GZ 或 TGZ 文件...${RESET}"
        tar -xvzf "$FILE" -C "$DEST"
        ;;
    application/x-bzip2)
        echo -e "${GREEN}正在解压 TAR.BZ2 文件...${RESET}"
        tar -xvjf "$FILE" -C "$DEST"
        ;;
    *)
        echo -e "${RED}不支持的压缩格式或未知类型: $TYPE${RESET}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 解压完成！文件已放到: $DEST${RESET}"
