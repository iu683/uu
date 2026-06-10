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

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}        ◈  多目录安全解压工具  ◈         ${RESET}"
echo -e "${GREEN}========================================${RESET}"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

# ===============================
# 自动识别包管理器
# ===============================
detect_pm() {
    if command -v apk >/dev/null 2>&1; then
        PM="apk"
        INSTALL="apk add --no-cache"
        UPDATE="true"
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

if [ ! -f "$FILE" ]; then
    echo -e "${RED}❌ 文件不存在！退出${RESET}"
    exit 1
fi

# 交互输入目标路径
echo -ne "请输入解压到的目标目录（默认当前目录 [ $(pwd) ]）："
read -r DEST
DEST=${DEST:-$(pwd)}

mkdir -p "$DEST"

# --- 新增密码输入逻辑 ---
# 提示：由于 sh 兼容性考虑，部分极度精简的 sh 环境不支持 read -s
# 这里采用通用跨平台隐式输入，如果系统支持 stty 则隐藏输入，不支持则明文
if command -v stty >/dev/null 2>&1; then
    echo -ne "${YELLOW}输入解压密码 (若无密码请直接回车): ${RESET}"
    stty -echo
    read -r PASSWORD
    stty echo
    echo ""
else
    echo -ne "${YELLOW}输入解压密码 (当前环境不支持隐藏输入，将明文显示，若无密码直接回车): ${RESET}"
    read -r PASSWORD
fi

FILENAME=$(basename "$FILE")
LOWER_NAME=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')

echo -e "${BLUE}🔍 正在识别文件类型...${RESET}"

case "$LOWER_NAME" in

    *.zip)
        install_pkg unzip
        echo -e "${GREEN}📦 正在解压 ZIP 文件...${RESET}"
        if [ -n "$PASSWORD" ]; then
            unzip -P "$PASSWORD" -o "$FILE" -d "$DEST"
        else
            unzip -o "$FILE" -d "$DEST"
        fi
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
        if [ -n "$PASSWORD" ]; then
            unrar x -p"$PASSWORD" -o+ "$FILE" "$DEST"
        else
            unrar x -o+ "$FILE" "$DEST"
        fi
        ;;

    *.7z)
        if [ "$PM" = "apk" ]; then
            install_pkg 7z p7zip
        elif [ "$PM" = "apt-get" ]; then
            install_pkg 7z p7zip-full
        else
            install_pkg 7z p7zip
        fi
        echo -e "${GREEN}📦 正在解压 7Z 文件...${RESET}"
        if [ -n "$PASSWORD" ]; then
            7z x "-p$PASSWORD" "$FILE" -o"$DEST" -y
        else
            7z x "$FILE" -o"$DEST" -y
        fi
        ;;

    # --- 新增：支持 OpenSSL 强加密的 tar 包一键解压 (.enc 结尾) ---
    *.tar.gz.enc|*.tgz.enc)
        install_pkg openssl
        if [ -z "$PASSWORD" ]; then
            echo -e "${RED}❌ 该文件已被 OpenSSL 加密，必须输入密码才能解压！${RESET}"
            exit 1
        fi
        echo -e "${GREEN}🔒 正在解密并解压加密的 TAR.GZ 文件...${RESET}"
        openssl aes-256-cbc -d -salt -pbkdf2 -k "$PASSWORD" -in "$FILE" 2>/dev/null | tar -xvzf - -C "$DEST"
        ;;

    *.tar.xz.enc)
        install_pkg openssl
        if [ -z "$PASSWORD" ]; then
            echo -e "${RED}❌ 该文件已被 OpenSSL 加密，必须输入密码才能解压！${RESET}"
            exit 1
        fi
        echo -e "${GREEN}🔒 正在解密并解压加密的 TAR.XZ 文件...${RESET}"
        openssl aes-256-cbc -d -salt -pbkdf2 -k "$PASSWORD" -in "$FILE" 2>/dev/null | tar -xvJf - -C "$DEST"
        ;;

    *.tar.bz2.enc)
        install_pkg openssl
        if [ -z "$PASSWORD" ]; then
            echo -e "${RED}❌ 该文件已被 OpenSSL 加密，必须输入密码才能解压！${RESET}"
            exit 1
        fi
        echo -e "${GREEN}🔒 正在解密并解压加密的 TAR.BZ2 文件...${RESET}"
        openssl aes-256-cbc -d -salt -pbkdf2 -k "$PASSWORD" -in "$FILE" 2>/dev/null | tar -xvjf - -C "$DEST"
        ;;

    *)
        echo -e "${RED}❌ 不支持的压缩格式: $FILENAME${RESET}"
        exit 1
        ;;
esac

echo -e "${GREEN}✅ 解压完成！文件已放到: $DEST${RESET}"
