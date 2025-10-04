#!/bin/bash
# ========================================
# 代理协议一键菜单（o/O 快捷键，独立版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"
BOLD="\033[1m"

SCRIPT_PATH="/root/proxy.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"
BIN_LINK_DIR="/usr/local/bin"

# =============================
# 首次运行自动安装
# =============================
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}首次运行，正在保存脚本到 $SCRIPT_PATH ...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/f"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/F"
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}💡 快捷键已添加：f 或 F 可快速启动${RESET}"
fi

# =============================
# 菜单函数
# =============================
show_menu() {
    echo -e "$BLUE}======= 代理协议一键安装菜单 ========${RESET}"
    echo -e "${YELLOW}[01] 老王 Sing-box 四合一${RESET}"
    echo -e "${YELLOW}[02] 老王 Xray-2go 一键脚本${RESET}"
    echo -e "${YELLOW}[03] mack-a 八合一脚本${RESET}"
    echo -e "${YELLOW}[04] Sing-box-yg${RESET}"
    echo -e "${YELLOW}[05] Hysteria2${RESET}"
    echo -e "${YELLOW}[06] Tuic${RESET}"
    echo -e "${YELLOW}[07] Reality${RESET}"
    echo -e "${YELLOW}[08] Snell${RESET}"
    echo -e "${YELLOW}[09] MTProto${RESET}"
    echo -e "${YELLOW}[10] Anytls${RESET}"
    echo -e "${YELLOW}[11] 3XUI管理${RESET}"
    echo -e "${YELLOW}[12] MTProxy(Docker)${RESET}"
    echo -e "${YELLOW}[13] GOST管理${RESET}"
    echo -e "${YELLOW}[14] Realm管理${RESET}"
    echo -e "${YELLOW}[15] Alpine转发${RESET}"
    echo -e "${YELLOW}[16] FRP管理${RESET}"
    echo -e "${YELLOW}[17] SS+SNELL${RESET}"
    echo -e "${YELLOW}[18] Hysteria2(Alpine)${RESET}"
    echo -e "${YELLOW}[19] S-UI面板${RESET}"
    echo -e "${YELLOW}[20] H-UI面板${RESET}"
    echo -e "${YELLOW}[21] NodePass面板${RESET}"
    echo -e "${YELLOW}[22] 哆啦A梦转发面板${RESET}"
    echo -e "${YELLOW}[23] 极光面板${RESET}"
    echo -e "${YELLOW}[24] BBR管理${RESET}"
    echo -e "${YELLOW}[25] Socks5${RESET}"
    echo -e "${YELLOW}[26] WireGuard${RESET}"
    echo -e "${YELLOW}[27] Xboard${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${GREEN}[00] 退出脚本${RESET}"
    echo -ne "${RED}请输入选项: ${RESET}"
    read choice
    install_protocol "$choice"
}
# =============================
# 协议安装函数
# =============================
install_protocol() {
    case "$1" in
        01|1) bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sing-box.sh) ;;
        02|2) bash <(curl -Ls https://github.com/eooce/xray-2go/raw/main/xray_2go.sh) ;;
        03|3) wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh && /root/install.sh ;;
        04|4) bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh) ;;
        05|5) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/Hysteria2.sh) ;;
        06|6) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/tuicv5.sh) ;;
        07|7) bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) ;;
        08|8) wget -O snell.sh --no-check-certificate https://git.io/Snell.sh && chmod +x snell.sh && ./snell.sh ;;
        09|9) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/MTProto.sh) ;;
        10) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/anytls.sh) ;;
        11) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/3xui.sh) ;;
        12) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/dkmop.sh) ;;
        13) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/gost.sh) ;;
        14) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/Realm.sh) ;;
        15) curl -sS -O https://raw.githubusercontent.com/zyxinab/iptables-manager/main/iptables-manager.sh && chmod +x iptables-manager.sh && ./iptables-manager.sh ;;
        16) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/FRP.sh) ;;
        17) bash <(curl -L -s menu.jinqians.com) ;;
        18) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu//proxy/main/aphy2.sh) ;;
        19) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/s-ui.sh) ;;
        20) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/H-UI.sh) ;;
        21) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/NodePass.sh) ;;
        22) bash <(curl -sL https://raw.githubusercontent.com/Polarisiu/proxy/main/dlam.sh) ;;
        23) bash <(curl -fsSL https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh) ;;
        24) wget --no-check-certificate -O tcpx.sh https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh && chmod +x tcpx.sh && ./tcpx.sh ;;
        25) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/socks5.sh) ;;
        26) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/wireguard.sh) ;;
        26) bash <(curl -fsSL https://raw.githubusercontent.com/Polarisiu/proxy/main/Xboard.sh) ;;
        88|088)
            echo -e "${GREEN}🔄 更新脚本...${RESET}"
            curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
            chmod +x "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/o"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/O"
            echo -e "${GREEN}✅ 更新完成! 可直接使用 F/f 启动脚本${RESET}"
            exec "$SCRIPT_PATH"
            ;;
        99|099)
            echo -e "${YELLOW}正在卸载脚本...${RESET}"
            rm -f "$SCRIPT_PATH"
            rm -f "$BIN_LINK_DIR/o" "$BIN_LINK_DIR/O"
            echo -e "${GREEN}✅ 脚本和快捷键已卸载${RESET}"
            exit 0
            ;;
        00) exit 0 ;;
        *) echo -e "${RED}无效选择，请重试${RESET}" ;;
    esac
}

# =============================
# 主循环
# =============================
while true; do
    show_menu
done
