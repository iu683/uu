#!/bin/bash
# ========================================
# 代理协议一键菜单（f/F 快捷键，独立版）
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"
BOLD="\033[1m"
ORANGE='\033[38;5;208m'

SCRIPT_PATH="/root/proxy.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
BIN_LINK_DIR="/usr/local/bin"

# =============================
# 首次运行自动安装
# =============================
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 安装失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/f"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/F"
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}✅ 快捷键已添加：f 或 F 可快速启动${RESET}"
fi

# =============================
# 菜单函数
# =============================
show_menu() {
    clear
    echo -e "${ORANGE}======= 代理协议安装菜单 ========${RESET}"
    echo -e "${YELLOW}[01] 老王Sing-box四合一${RESET}"
    echo -e "${YELLOW}[02] 老王Xray-2go一键脚本${RESET}"
    echo -e "${YELLOW}[03] mack-a八合一脚本${RESET}"
    echo -e "${YELLOW}[04] Sing-box-yg${RESET}"
    echo -e "${YELLOW}[05] fscarmen-ArgoX${RESET}"
    echo -e "${YELLOW}[06] Anytls${RESET}"
    echo -e "${YELLOW}[07] Hysteria2${RESET}"
    echo -e "${YELLOW}[08] Tuic${RESET}"
    echo -e "${YELLOW}[09] Reality${RESET}"
    echo -e "${YELLOW}[10] Snell${RESET}"
    echo -e "${YELLOW}[11] MTProto${RESET}"
    echo -e "${YELLOW}[12] MTProxy(Docker)${RESET}"
    echo -e "${YELLOW}[13] Shadowsocks${RESET}"
    echo -e "${YELLOW}[14] Socks5${RESET}"
    echo -e "${YELLOW}[15] SS+SNELL${RESET}"
    echo -e "${YELLOW}[16] 3XUI管理${RESET}"
    echo -e "${YELLOW}[17] S-UI面板${RESET}"
    echo -e "${YELLOW}[18] H-UI面板${RESET}"
    echo -e "${YELLOW}[19] GOST管理${RESET}"
    echo -e "${YELLOW}[20] Realm管理${RESET}"
    echo -e "${YELLOW}[21] FRP管理${RESET}"
    echo -e "${YELLOW}[22] 哆啦A梦转发面板${RESET}"
    echo -e "${YELLOW}[23] 极光面板${RESET}"
    echo -e "${YELLOW}[24] Xboard${RESET}"
    echo -e "${YELLOW}[25] WireGuard${RESET}"
    echo -e "${YELLOW}[26] WARP${RESET}"
    echo -e "${YELLOW}[27] BBR+TCP智能调参${RESET}"
    echo -e "${YELLOW}[28] 自建DNS解锁服务${RESET}"
    echo -e "${YELLOW}[29] 自定义DNS解锁${RESET}"
    echo -e "${YELLOW}[30] 多协议代理部署${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${YELLOW}[00] 退出脚本${RESET}"
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
        05|5) bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) ;;
        06|6) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/anytls.sh) ;;
        07|7) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Hysteria2.sh) ;;
        08|8) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/tuicv5.sh) ;;
        09|9) bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) ;;
        10) wget -O snell.sh --no-check-certificate https://git.io/Snell.sh && chmod +x snell.sh && ./snell.sh ;;
        11) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/MTProto.sh) ;;
        12) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/dkmop.sh) ;;
        13) wget -O ss-rust.sh --no-check-certificate https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh && chmod +x ss-rust.sh && ./ss-rust.sh ;;
        14) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/socks5.sh) ;;
        15) bash <(curl -L -s menu.jinqians.com) ;;
        16) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/3xui.sh) ;;
        17) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/s-ui.sh) ;;
        18) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/H-UI.sh) ;;
        19) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/gost.sh) ;;
        20) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/realmdog.sh) ;;
        21) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/FRP.sh) ;;
        22) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/dlam.sh) ;;
        23) bash <(curl -fsSL https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh) ;;
        24) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Xboard.sh) ;;
        25) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/wireguard.sh) ;;
        26) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh [option] [lisence/url/token] ;;
        27) bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) ;;
        28) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/DNSsnp.sh) ;;
        29) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/unlockdns.sh) ;;
        30) wget -O vless-server.sh https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-server.sh && bash vless-server.sh ;;
        88|088)
            echo -e "${GREEN}🔄 更新脚本...${RESET}"
            curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
            chmod +x "$SCRIPT_PATH"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/F"
            ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/f"
            echo -e "${GREEN}✅ 更新完成! 可直接使用 F/f 启动脚本${RESET}"
            exec "$SCRIPT_PATH"
            ;;
        99|099)
            echo -e "${YELLOW}正在卸载脚本...${RESET}"
            rm -f "$SCRIPT_PATH"
            rm -f "$BIN_LINK_DIR/F" "$BIN_LINK_DIR/f"
            echo -e "${GREEN}✅ 脚本已卸载${RESET}"
            exit 0
            ;;
        00|0) exit 0 ;;
        *) echo -e "${RED}无效选择，请重试${RESET}" ;;
    esac
}

# =============================
# 主循环
# =============================
while true; do
    show_menu
done
