#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# =============================
# 脚本路径
# =============================
SCRIPT_PATH="/root/panel.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
BIN_LINK_DIR="/usr/local/bin"

# =============================
# 暂停
# =============================
pause() {
    read -p $'\033[32m按回车键返回菜单...\033[0m'
}

# =============================
# 菜单
# =============================
menu() {
    clear

    echo -e "${GREEN}====== 面板管理总菜单 ======${RESET}"
    echo -e "${GREEN}[01] 宝塔面板${RESET}"
    echo -e "${GREEN}[02] 国际版宝塔${RESET}"
    echo -e "${GREEN}[03] 开心版宝塔${RESET}"
    echo -e "${GREEN}[04] 1Panel 面板${RESET}"
    echo -e "${GREEN}[05] 1Panel 面板拓展应用${RESET}"
    echo -e "${GREEN}[06] 1Panel v1 开心版${RESET}"
    echo -e "${GREEN}[07] 1Panel v2 开心版${RESET}"
    echo -e "${GREEN}[08] 耗子面板${RESET}"
    echo -e "${GREEN}[09] PandaWiki文档${RESET}"
    echo -e "${GREEN}[10] 雷池WAF${RESET}"
    echo -e "${YELLOW}[88] 更新脚本${RESET}"
    echo -e "${YELLOW}[99] 卸载脚本${RESET}"
    echo -e "${GREEN}[00] 退出${RESET}"
    read -p $'\033[32m请选择操作: \033[0m' choice

    case $choice in
        1|01)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/baota.sh)
            pause
            ;;
        2|02)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/gjbaota.sh)
            pause
            ;;
        3|03)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/kxbaota.sh)
            pause
            ;;
        4|04)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/1Panel.sh)
            pause
            ;;
        5|05)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/tz1panel.sh)
            pause
            ;;
        6|06)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/kx1Panelv1.sh)
            pause
            ;;
        7|07)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/kx1Panelv2.sh)
            pause
            ;;
        8|08)
            bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/panel/main/haozi.sh)
            pause
            ;;
        9|09)
            bash -c "$(curl -fsSLk https://release.baizhi.cloud/panda-wiki/manager.sh)"
            pause
            ;;
        10)
            bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/manager.sh)"
            pause
            ;;

        # =============================
        # 更新脚本
        # =============================
        88)
            echo -e "${YELLOW}🔄 正在更新脚本...${RESET}"
            curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
            chmod +x "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/p"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/P"
            echo -e "${GREEN}✅ 脚本已更新，可使用 p / P 启动${RESET}"
            exec "$SCRIPT_PATH"
            ;;

        # =============================
        # 卸载脚本
        # =============================
        99)
            echo -e "${YELLOW}正在卸载脚本...${RESET}"
            rm -f "$BIN_LINK_DIR/p" "$BIN_LINK_DIR/P" "$SCRIPT_PATH"
            echo -e "${GREEN}✅ 卸载完成${RESET}"
            exit 0
            ;;

        00|0)
            exit 0
            ;;

        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            pause
            ;;
    esac

    menu
}

# =============================
# 首次运行自动安装（同 oracle.sh）
# =============================
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/p"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/P"

    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}✅ 快捷键：p 或 P 可快速启动${RESET}"
fi

menu
