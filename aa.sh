#!/bin/bash
# ========================================
# 代理协议一键菜单（一级+二级分类版）
# 二级菜单 0 返回 | x 退出 | 自动补零 | 循环菜单
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

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行！${RESET}"
    exit 1
fi

# =============================
# 首次运行自动安装
# =============================
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/f"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/F"
    echo -e "${GREEN}✅ 安装完成，输入 f 或 F 启动${RESET}"
fi

# =============================
# 自动补零
# =============================
format_choice() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        printf "%02d" "$1"
    else
        echo "$1"
    fi
}
# =============================
# 通用菜单读取（一级用）
# =============================
read_mainmenu() {
    echo -ne "${RED}请选择: ${RESET}"
    read choice

    choice=$(echo "$choice" | xargs)

    [[ "$choice" =~ ^[xX]$ ]] && exit 0
    [[ "$choice" == "0" || "$choice" == "00" ]] && exit 0

    choice=$(format_choice "$choice")
}

# =============================
# 通用二级菜单读取逻辑
# =============================
read_submenu() {
    echo -ne "${RED}选择: ${RESET}"
    read sub

    sub=$(echo "$sub" | xargs)

    [[ "$sub" =~ ^[xX]$ ]] && exit 0
    [[ "$sub" == "0" || "$sub" == "00" ]] && return 1

    sub=$(format_choice "$sub")
    return 0
}

pause_return() {
    echo
    read -p "$(echo -e ${GREEN}按回车返回菜单...${RESET})"
}
# =============================
# 一级菜单
# =============================
main_menu() {
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      代理管理中心        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] 单协议安装类${RESET}"
    echo -e "${YELLOW}[02] 多协议安装类${RESET}"
    echo -e "${YELLOW}[03] 面板管理类${RESET}"
    echo -e "${YELLOW}[04] 转发管理类${RESET}"
    echo -e "${YELLOW}[05] 组网管理类${RESET}"
    echo -e "${YELLOW}[06] 网络优化类${RESET}"
    echo -e "${YELLOW}[07] DNS 解锁类${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${YELLOW}[00] 退出${RESET}"

    read_mainmenu

    case "$choice" in
        01) protocol_menu ;;
        02) protocols_menu ;;
        03) panel_menu ;;
        04) zfpanel_menu ;;
        05) zwpanel_menu ;;
        06) network_menu ;;
        07) dns_menu ;;
        88) update_script ; pause_return ;;
        99) uninstall_script ;;
        00) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
}

# =============================
# 单协议类
# =============================
protocol_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      单协议安装类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] Shadowsocks${RESET}"
    echo -e "${YELLOW}[02] Reality${RESET}"
    echo -e "${YELLOW}[03] Snell${RESET}"
    echo -e "${YELLOW}[04] Anytls${RESET}"
    echo -e "${YELLOW}[05] Hysteria2${RESET}"
    echo -e "${YELLOW}[06] Tuicv5${RESET}"
    echo -e "${YELLOW}[07] MTProto${RESET}"
    echo -e "${YELLOW}[08] MTProxy(Docker)${RESET}"
    echo -e "${YELLOW}[09] Socks5${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"

    read_submenu || return

    case "$sub" in
        01) wget -O ss-rust.sh https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh && bash ss-rust.sh ; pause_return ;;
        02) bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) ; pause_return ;;
        03) wget -O snell.sh --no-check-certificate https://git.io/Snell.sh && chmod +x snell.sh && ./snell.sh ; pause_return ;;
        04) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/anytls.sh) ; pause_return ;;
        05) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Hysteria2.sh) ; pause_return ;;
        06) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/tuicv5.sh) ; pause_return ;;
        07) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/MTProto.sh) ; pause_return ;;
        08) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/dkmop.sh) ; pause_return ;;
        09) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/socks5.sh) ; pause_return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# 多协议类
# =============================
protocols_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      多协议安装类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] 老王Sing-box${RESET}"
    echo -e "${YELLOW}[02] 老王Xray-Argo${RESET}"
    echo -e "${YELLOW}[03] mack-a八合一${RESET}"
    echo -e "${YELLOW}[04] ygSing-box${RESET}"
    echo -e "${YELLOW}[05] fscarmen-ArgoX${RESET}"
    echo -e "${YELLOW}[06] 233boySing-box${RESET}"
    echo -e "${YELLOW}[07] SS+SNELL${RESET}"
    echo -e "${YELLOW}[08] VlessallInOne多协议代理${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"

    read_submenu || return

    case "$sub" in
        01) bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sing-box.sh) ; pause_return ;;
        02) bash <(curl -Ls https://github.com/eooce/xray-2go/raw/main/xray_2go.sh) ; pause_return ;;
        03) wget -O install.sh https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh && bash install.sh ; pause_return ;;
        04) bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh) ; pause_return ;;
        05) bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) ; pause_return ;;
        06) bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh) ; pause_return ;;
        07) bash <(curl -L -s menu.jinqians.com) ; pause_return ;;
        08) wget -O vless-server.sh https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-server.sh && bash vless-server.sh ; pause_return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# 二级菜单：面板类
# =============================
panel_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      面板管理类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] 3X-UI${RESET}"
    echo -e "${YELLOW}[02] S-UI${RESET}"
    echo -e "${YELLOW}[03] H-UI${RESET}"
    echo -e "${YELLOW}[04] Xboard${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"
    
    read_submenu || return

    case "$sub" in
        01) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/3xui.sh) ; pause_return ;;
        02) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/s-ui.sh) ; pause_return ;;
        03) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/H-UI.sh) ; pause_return ;;
        04) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Xboard.sh) ; pause_return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# 二级菜单：转发类
# =============================
zfpanel_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      转发管理类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] Realm管理${RESET}"
    echo -e "${YELLOW}[02] GOST管理${RESET}"
    echo -e "${YELLOW}[03] 极光面板${RESET}"
    echo -e "${YELLOW}[04] 哆啦A梦转发面板${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"
    
    read_submenu || return

    case "$sub" in
        01) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/realmdog.sh) ; pause_return ;;
        02) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/gost.sh) ; pause_return ;;
        03) bash <(curl -fsSL https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh) ; pause_return ;;
        04) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/dlam.sh) ; pause_return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# 二级菜单：组网类
# =============================
zwpanel_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      组网管理类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] FRP管理${RESET}"
    echo -e "${YELLOW}[02] WireGuard${RESET}"
    echo -e "${YELLOW}[03] WG-Easy${RESET}"
    echo -e "${YELLOW}[04] easytier组网${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"
    
    read_submenu || return
  

    case "$sub" in
        01) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/FRP.sh) ; pause_return ;;
        02) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/wireguard.sh) ; pause_return ;;
        03) bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/WGEasy.sh) ; pause_return ;;
        04) bash <(curl -sL https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/easytier.sh) ; pause_return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}
# =============================
# 网络优化
# =============================
network_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      网络优化类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] BBR管理${RESET}"
    echo -e "${YELLOW}[02] TCP窗口调优${RESET}"
    echo -e "${YELLOW}[03] WARP管理${RESET}"
    echo -e "${YELLOW}[04] BBRv3优化脚本${RESET}"
    echo -e "${YELLOW}[05] BBR+TCP调优${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"
    
    read_submenu || return

    case "$sub" in
        01) wget --no-check-certificate -O tcpx.sh https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh && chmod +x tcpx.sh && ./tcpx.sh ; pause_return ;;
        02) wget http://sh.nekoneko.cloud/tools.sh -O tools.sh && bash tools.sh ; pause_return ;;
        03) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ; pause_return ;;
        04)  bash <(curl -fsSL "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/install-alias.sh?$(date +%s)") ; pause_return ;;
        05) bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) ; pause_return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# DNS 类
# =============================
dns_menu() {
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      DNS 解锁类        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] DDNS${RESET}"
    echo -e "${YELLOW}[02] 自建DNS解锁${RESET}"
    echo -e "${YELLOW}[03] 自定义DNS解锁${RESET}"
    echo -e "${GREEN}[0]  返回${RESET}"
    echo -e "${GREEN}[x]  退出${RESET}"
    
    read_submenu || return
   

    case "$sub" in
        01) bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh) ; pause_return ;;
        02) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/DNSsnp.sh) ; pause_return ;;
        03) bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/unlockdns.sh) ; pause_return ;;
        0) return ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
}

# =============================
# 更新 & 卸载
# =============================
update_script() {
    echo -e "${GREEN}更新中...${RESET}"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 更新完成!${RESET}"
    exec "$SCRIPT_PATH"
}

uninstall_script() {
    rm -f "$SCRIPT_PATH"
    rm -f "$BIN_LINK_DIR/F" "$BIN_LINK_DIR/f"
    echo -e "${RED}✅ 脚本已卸载${RESET}"
    exit 0
}

# =============================
# 主循环
# =============================
while true; do
    main_menu
done
