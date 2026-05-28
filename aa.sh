#!/bin/bash
set -euo pipefail

# =========================================================
# Tuic v5 安装/卸载管理脚本 
# =========================================================

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="1.0"
SERVICE_NAME="tuic"
TUIC_DIR="/root/tuic"
CONFIG="$TUIC_DIR/config.json"
SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

# ================== Root 检查 ==================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 运行${RESET}"
    exit 1
fi

# ================== 暂停返回 ==================
pause() {
    read -n1 -s -r -p "按任意键返回菜单..." < /dev/tty
    echo
}

# ================== 检查依赖 ==================
install_packages() {
    local pkgs=(jq curl openssl wget)
    local to_install=()
    for p in "${pkgs[@]}"; do
        command -v "$p" &>/dev/null || to_install+=("$p")
    done
    
    if [ ${#to_install[@]} -gt 0 ]; then
        if command -v apt &>/dev/null; then
            apt-get update -y && apt-get install -y "${to_install[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y "${to_install[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y "${to_install[@]}"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${to_install[@]}"
        else
            echo -e "${YELLOW}暂不支持的系统组件管理器${RESET}"
            exit 1
        fi
    fi
}

# ================== 检测架构 ==================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        armv7l) echo "armv7-unknown-linux-gnueabi" ;;
        i686) echo "i686-unknown-linux-gnu" ;;
        *) 
            echo -e "${RED}不支持架构 $(uname -m)${RESET}"
            exit 1 
            ;;
    esac
}

# ================== 自动获取 GitHub 最新版本号 ==================
get_latest_version() {
    local latest_release
    latest_release=$(curl -fsSL --max-time 5 "https://api.github.com/repos/etjec4/tuic/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$latest_release" ]]; then
        latest_release=$(curl -fsSLI --max-time 5 "https://github.com/etjec4/tuic/releases/latest" 2>/dev/null | grep -i 'location:' | sed -E 's/.*\/v?([^/\r\n]+).*/\1/')
    fi
    echo "${latest_release:-1.0.0}"
}

# ================== 随机生成器 ==================
random_port() {
    shuf -i 10000-65000 -n 1
}

random_password() {
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 12 || true
}

# ================== 下载并安装 Tuic ==================
install_tuic() {
    echo -e "${GREEN}[信息] 开始安装 Tuic V5...${RESET}"
    install_packages
    mkdir -p "$TUIC_DIR"
    cd "$TUIC_DIR"

    local arch version url
    arch=$(detect_arch)
    
    echo -e "${GREEN}[信息] 正在动态获取 Tuic 最新版本...${RESET}"
    version=$(get_latest_version)
    echo -e "${GREEN}[信息] 检测到最新版本为: v${version}${RESET}"
    
    url="https://github.com/etjec4/tuic/releases/download/${version}/tuic-server-${version}-${arch}"

    echo -e "${GREEN}[信息] 开始下载 Tuic 服务端 (v${version})...${RESET}"
    if ! wget -O tuic-server -q "$url"; then
        echo -e "${YELLOW}[警告] wget 下载失败，尝试切换到 curl...${RESET}"
        curl -fsSL -o tuic-server "$url" || { echo -e "${RED}[错误] 核心程序下载失败${RESET}"; return 1; }
    fi
    chmod +x tuic-server
    echo "$version" > "${TUIC_DIR}/version.txt"

    echo -e "${GREEN}[信息] 正在自签发本地证书...${RESET}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout server.key -out server.crt -subj "/CN=www.bing.com" -days 36500 &>/dev/null

    local port input_port
    while true; do
        read -p "请输入监听端口 (10000-65000，默认随机): " input_port < /dev/tty
        port=${input_port:-$(random_port)}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        fi
        echo -e "${RED}端口无效${RESET}"
    done

    local password uuid
    password=$(random_password)
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

    cat > "$CONFIG" <<EOF
{
  "server": "[::]:$port",
  "users": {
    "$uuid": "$password"
  },
  "certificate": "$TUIC_DIR/server.crt",
  "private_key": "$TUIC_DIR/server.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": true,
  "dual_stack": true,
  "log_level": "warn"
}
EOF

    cat > "$SERVICE" <<EOF
[Unit]
Description=Tuic Service
After=network.target nss-lookup.target

[Service]
WorkingDirectory=$TUIC_DIR
ExecStart=$TUIC_DIR/tuic-server -c $CONFIG
Restart=on-failure
User=root
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tuic &>/dev/null
    systemctl restart tuic

    if systemctl is-active --quiet tuic; then
        echo -e "${GREEN}[完成] Tuic V5 安装并启动成功${RESET}"
        show_info
    else
        echo -e "${RED}[错误] Tuic 服务启动失败${RESET}"
    fi
}

# ================== 🌟 核心修改：更新 Tuic 主程序 ==================
update_tuic() {
    if [[ ! -f "${TUIC_DIR}/tuic-server" || ! -f "$CONFIG" ]]; then
        echo -e "${RED}[错误] 未检测到已安装的 Tuic 服务，请先执行安装。${RESET}"
        return 1
    fi

    local current_version="未知"
    [[ -f "${TUIC_DIR}/version.txt" ]] && current_version=$(cat "${TUIC_DIR}/version.txt")
    
    echo -e "${GREEN}[信息] 正在获取最新版本...${RESET}"
    local latest_version
    latest_version=$(get_latest_version)

    echo -e "${GREEN}当前版本: v${current_version}${RESET}"
    echo -e "${GREEN}最新版本: v${latest_version}${RESET}"

    if [[ "$current_version" == "$latest_version" ]]; then
        read -p "当前已是最新版本，是否仍要重新下载覆盖？[y/N]: " remode < /dev/tty
        if [[ ! "$remode" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已取消更新。${RESET}"
            return 0
        fi
    fi

    echo -e "${GREEN}[信息] 开始升级主程序到 v${latest_version}...${RESET}"
    local arch
    arch=$(detect_arch)
    local url="https://github.com/etjec4/tuic/releases/download/${latest_version}/tuic-server-${latest_version}-${arch}"

    cd "$TUIC_DIR"
    if ! wget -O tuic-server.tmp -q "$url"; then
        echo -e "${YELLOW}[警告] wget 下载失败，尝试切换到 curl...${RESET}"
        curl -fsSL -o tuic-server.tmp "$url" || { echo -e "${RED}[错误] 下载失败${RESET}"; return 1; }
    fi

    # 停止服务，替换文件，随后恢复
    systemctl stop tuic || true
    mv -f tuic-server.tmp tuic-server
    chmod +x tuic-server
    echo "$latest_version" > "${TUIC_DIR}/version.txt"
    systemctl start tuic

    if systemctl is-active --quiet tuic; then
        echo -e "${GREEN}[完成] Tuic 成功升级至 v${latest_version}!${RESET}"
    else
        echo -e "${RED}[错误] 升级后服务启动失败，请检查日志。${RESET}"
    fi
}

# ================== 修改端口 ==================
change_port() {
    if [[ ! -f "$CONFIG" ]]; then
        echo -e "${RED}[错误] 配置文件不存在，请先安装。${RESET}"
        return 1
    fi

    local new_port input_port
    while true; do
        read -p "请输入新端口 (10000-65000，默认随机): " input_port < /dev/tty
        new_port=${input_port:-$(random_port)}
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            break
        fi
        echo -e "${RED}端口无效${RESET}"
    done

    local tmp_json
    tmp_json=$(jq ".server=\"[::]:$new_port\"" "$CONFIG")
    echo "$tmp_json" > "$CONFIG"
    
    systemctl restart tuic
    echo -e "${GREEN}修改成功${RESET}"
    show_info
}

# ================== 卸载 ==================
uninstall_tuic() {
    systemctl stop tuic || true
    systemctl disable tuic || true
    rm -f "$SERVICE"
    systemctl daemon-reload
    rm -rf "$TUIC_DIR"
    echo -e "${GREEN}卸载完成${RESET}"
}

# ================== 显示节点信息 ==================
show_info() {
    if [[ ! -f "$CONFIG" ]]; then
        echo -e "${RED}[错误] 配置不存在${RESET}"
        return 1
    fi

    local public_ip uuid password port hostname
    public_ip=$(curl -fsSL --max-time 5 https://api.ipify.org || echo "无法获取公网IP")
    uuid=$(jq -r '.users | keys[0]' "$CONFIG")
    password=$(jq -r '.users[]' "$CONFIG")
    port=$(jq -r '.server' "$CONFIG" | sed -E 's/.*:([0-9]+)$/\1/')
    hostname=$(hostname -s | sed 's/ /_/g')

    echo -e "\n${GREEN}====== Tuic v5 节点信息 ======${RESET}"
    echo -e "${YELLOW}IP      : ${public_ip}${RESET}"
    echo -e "${YELLOW}端口    : ${port}${RESET}"
    echo -e "${YELLOW}UUID    : ${uuid}${RESET}"
    echo -e "${GREEN}---------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo -e "${YELLOW}[信息] V2rayN / NekoBox 链接：${RESET}"
    echo -e "${CYAN}tuic://$uuid:$password@$public_ip:$port?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#$hostname-tuicv5${RESET}"
    echo -e "${GREEN}---------------------------------${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status
    systemctl is-active --quiet tuic &&
        status="${GREEN}●运行中${RESET}" ||
        status="${RED}●未运行${RESET}"

    local version="未安装"
    [[ -f "${TUIC_DIR}/version.txt" ]] && version="v$(cat "${TUIC_DIR}/version.txt")"

    local port="-"
    [[ -f "$CONFIG" ]] && port=$(jq -r '.server' "$CONFIG" | sed -E 's/.*:([0-9]+)$/\1/')

    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}      TuicV5 管理面板 ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 Tuic V5${RESET}"
    echo -e "${GREEN}2. 更新 Tuic V5${RESET}"  
    echo -e "${GREEN}3. 卸载 Tuic V5${RESET}"  
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Tuic V5${RESET}"
    echo -e "${GREEN}6. 停止 Tuic V5${RESET}"
    echo -e "${GREEN}7. 重启 Tuic V5${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu

    set +e
    read -r -p $'\033[32m请输入选项: \033[0m' choice < /dev/tty
    set -e

    case $choice in
        1) install_tuic; pause ;;
        2) update_tuic; pause ;;  
        3) uninstall_tuic; pause ;;  
        4) change_port; pause ;;
        5) systemctl start tuic; echo -e "${GREEN}[完成] Tuic 已启动${RESET}"; pause ;;
        6) systemctl stop tuic; echo -e "${GREEN}[完成] Tuic 已停止${RESET}"; pause ;;
        7) systemctl restart tuic; echo -e "${GREEN}[完成] Tuic 已重启${RESET}"; pause ;;
        8) journalctl -u tuic -e --no-pager; pause ;;
        9) show_info; pause ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}无效输入${RESET}"
            pause
            ;;
    esac
done
