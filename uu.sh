#!/bin/bash

# ========= 配置 =========
SCRIPT_PATH="/usr/local/bin/byd"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/uu.sh" # ← 改成你的脚本地址

# ========= 颜色 =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[38;5;208m'
RESET='\033[0m'

# ========= root 检测 =========
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行${RESET}"
    exit 1
fi

# =============================
# 自动安装自身（关键逻辑）
# =============================
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "${YELLOW}正在安装代理工具箱...${RESET}"

    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH" || {
        echo -e "${RED}下载失败${RESET}"
        exit 1
    }

    chmod +x "$SCRIPT_PATH"

   
    echo -e "${GREEN}安装完成，输入 byd 快捷启动${RESET}"
    echo -e "${GREEN}正在启动...${RESET}"
    sleep 1

    exec "$SCRIPT_PATH"   
fi

# ========= 基础函数 =========
pause_return() {

    read -p $'\033[32m按回车返回菜单...\033[0m' temp
}

check_net() {
    ping -c1 github.com >/dev/null 2>&1 || {
        echo -e "${RED}网络异常${RESET}"
        return 1
    }
}

normalize_input() {
    local input
    input=$(echo "$1" | sed 's/^0*//')
    echo "${input:-0}"
}

run_cmd() {
    cmd="$1"
    check_net || return
    eval "$cmd"
    pause_return
}

# ========= 更新 =========
update_self() {
    echo -e "${YELLOW}正在更新脚本...${RESET}"
    check_net || return

    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH" || {
        echo -e "${RED}更新失败${RESET}"
        return
    }

    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}更新完成！${RESET}"
    pause_return
}

# ========= 卸载 =========
uninstall_self() {
    echo -e "${YELLOW}正在卸载工具箱...${RESET}"
    rm -f "$SCRIPT_PATH"
    echo -e "${RED}卸载完成${RESET}"
    exit 0
}

# ========= 菜单 =========
while true; do
    clear
    echo -e "${ORANGE}╔══════════════════════╗${RESET}"
    echo -e "${ORANGE}      代理工具箱        ${RESET}"
    echo -e "${ORANGE}╚══════════════════════╝${RESET}"
    echo -e "${YELLOW}[01] Shadowsocks${RESET}"
    echo -e "${YELLOW}[02] Reality${RESET}"
    echo -e "${YELLOW}[03] Snell${RESET}"
    echo -e "${YELLOW}[04] Anytls${RESET}"
    echo -e "${YELLOW}[05] Hysteria2${RESET}"
    echo -e "${YELLOW}[06] Tuicv5${RESET}"
    echo -e "${YELLOW}[07] MTProto${RESET}"
    echo -e "${YELLOW}[08] Socks5${RESET}"
    echo -e "${YELLOW}[09] NaiveProxy${RESET}"
    echo -e "${YELLOW}[10] Reality(Alpine)${RESET}"
    echo -e "${YELLOW}[11] Hysteria2(Alpine)${RESET}"
    echo -e "${YELLOW}[12] Xray-Argo${RESET}"
    echo -e "${YELLOW}[13] F佬Sing-box${RESET}"
    echo -e "${YELLOW}[14] vless-all-in-one${RESET}"
    echo -e "${YELLOW}[15] Realm-xwPF${RESET}"
    echo -e "${GREEN}[88] 更新脚本${RESET}"
    echo -e "${GREEN}[99] 卸载脚本${RESET}"
    echo -e "${RED}[0]  退出${RESET}"

    read -p $'\033[32m请输入选项: \033[0m' sub
    sub=$(normalize_input "$sub")

    case "$sub" in
        1) run_cmd "wget -O ss-rust.sh https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh && bash ss-rust.sh" ;;
        2) run_cmd "bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)" ;;
        3) run_cmd "wget -O snell.sh --no-check-certificate https://git.io/Snell.sh && chmod +x snell.sh && ./snell.sh" ;;
        4) run_cmd "bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Anytls.sh)" ;;
        5) run_cmd "bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/GLHysteria2.sh)" ;;
        6) run_cmd "bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/tuicv5.sh)" ;;
        7) run_cmd "bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/GLMTProto.sh)" ;;
        8) run_cmd "bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Socks5.sh)" ;;
        9) run_cmd "bash -c \"\$(curl -Ls https://raw.githubusercontent.com/dododook/NaiveProxy/refs/heads/main/install.sh?v=2)\"" ;;
        10) run_cmd "bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/AZAPReality.sh)" ;;
        11) run_cmd "bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Alpine/AZAPHysteria2.sh)" ;;
        12) run_cmd "bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/Xray2go.sh)" ;;
        13) run_cmd "bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh)" ;;
        14) run_cmd "wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && ./vless-server.sh" ;;
        15) run_cmd "wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install" ;;
        88) update_self ;;
        99) uninstall_self ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done
