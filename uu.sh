#!/bin/bash

# =============================
# 颜色定义
# =============================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"
BOLD="\033[1m"

# =============================
# 脚本路径
# =============================
SCRIPT_PATH="/root/oracle.sh"
SCRIPT_URL="https://raw.githubusercontent.com/Polarisiu/oracle/main/oracle.sh"
BIN_LINK_DIR="/usr/local/bin"

# =============================
# 暂停函数
# =============================
pause() {
    read -p "回车返回菜单..."
}

# =============================
# 菜单函数
# =============================
menu() {
    echo -e "${BLUE}====== 甲骨文管理菜单 ======${RESET}"
    echo -e "${YELLOW}[01] 甲骨文救砖${RESET}"
    echo -e "${YELLOW}[02] 开启 ROOT 登录${RESET}"
    echo -e "${YELLOW}[03] 一键重装系统${RESET}"
    echo -e "${YELLOW}[04] 恢复IPv6${RESET}"
    echo -e "${YELLOW}[05] 安装保活Oracle${RESET}"
    echo -e "${YELLOW}[06] 安装lookbusy保活${RESET}"
    echo -e "${YELLOW}[07] 安装Y探长${RESET}"
    echo -e "${YELLOW}[08] 安装oci-start${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${GREEN}[00] 退出${RESET}"
    echo -ne "${RED}请选择: ${RESET}"
    read choice
    case $choice in
        1)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/ocibrick.sh) && pause ;;
        2)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/tool/main/xgroot.sh) && pause ;;
        3)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/DDoracle.sh) && pause ;;
        4)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/ipv6.sh) && pause ;;
        5)  bash <(wget -qO- --no-check-certificate https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh) && pause ;;
        6)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/lookbusy.sh) && pause ;;
        7)  bash <(wget -qO- https://github.com/Yohann0617/oci-helper/releases/latest/download/sh_oci-helper_install.sh) && pause ;;
        8)  bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/oracle/main/oci-start.sh) && pause ;;
        88)
            echo -e "${YELLOW}🔄 正在更新脚本...${RESET}"
            curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
            chmod +x "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/o"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/O"
            echo -e "${GREEN}✅ 脚本已更新，可继续使用 o/O 启动${RESET}"
            exec "$SCRIPT_PATH"
            ;;
        99)
            echo -e "${YELLOW}正在卸载脚本...${RESET}"
            rm -f "$BIN_LINK_DIR/o" "$BIN_LINK_DIR/O" "$SCRIPT_PATH"
            echo -e "${GREEN}✅ 卸载完成${RESET}"
            exit 0
            ;;
        00) exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入${RESET}" && pause ;;
    esac
    menu
}

# =============================
# 首次运行自动安装
# =============================
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}首次运行，正在保存脚本到 $SCRIPT_PATH ...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/o"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/O"
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}💡 快捷键已添加：o 或 O 可快速启动${RESET}"
fi

menu
