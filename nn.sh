#!/bin/bash
# ========================================
# 开小鸡管理菜单
# 支持永久快捷键 N/n + 自动补零 + 循环菜单
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"
ORANGE='\033[38;5;208m'

SCRIPT_PATH="/root/nat.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"
BIN_LINK_DIR="/usr/local/bin"

# ================== 首次自动安装 ==================
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}首次运行，正在安装...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL" || {
        echo -e "${RED}安装失败，请检查网络${RESET}"
        exit 1
    }
    chmod +x "$SCRIPT_PATH"

    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/n"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/N"

    echo -e "${GREEN}✅ 安装完成，可使用 n 或 N 启动${RESET}"
fi

# ================== 菜单 ==================
menu() {
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      开小鸡工具箱       ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] PVE管理${RESET}"
    echo -e "${YELLOW}[02] LXC小鸡${RESET}"
    echo -e "${YELLOW}[03] Docker小鸡${RESET}"
    echo -e "${YELLOW}[04] Incus小鸡${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${YELLOW}[00] 退出${RESET}"
    echo -ne "${RED}请输入操作编号: ${RESET}"

    read choice

    # 只允许数字
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}请输入数字编号！${RESET}"
        sleep 1
        return
    fi

    choice=$(printf "%02d" "$choice")

    case "$choice" in
        01)
            echo -e "${GREEN}正在运行 PVE管理...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/toy/pvegl.sh)
            ;;
        02)
            echo -e "${GREEN}正在运行 LXC 小鸡脚本...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/toy/lxc.sh)
            ;;
        03)
            echo -e "${GREEN}正在运行 Docker 小鸡脚本...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/toy/dockerlxc.sh)
            ;;
        04)
            echo -e "${GREEN}正在运行 Incus 小鸡脚本...${RESET}"
            bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/toy/incus.sh)
            ;;
        88)
            echo -e "${YELLOW}🔄 正在更新脚本...${RESET}"
            curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL" || {
                echo -e "${RED}更新失败，请检查网络${RESET}"
                break
            }
            chmod +x "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/n"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/N"
            echo -e "${GREEN}✅ 更新完成${RESET}"
            exec "$SCRIPT_PATH"
            ;;
        99)
            rm -f "$SCRIPT_PATH" "$BIN_LINK_DIR/n" "$BIN_LINK_DIR/N"
            echo -e "${RED}✅ 已卸载${RESET}"
            exit 0
            ;;
        00)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            sleep 1
            return
            ;;
    esac

    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
}

# ================== 主循环 ==================
while true; do
    menu
done
