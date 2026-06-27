#!/bin/bash
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 (已全部加上 v6 后缀独立化) ==================
SNELL_DIR="/etc/snellv6"
SNELL_CONFIG="$SNELL_DIR/snell-server-v6.conf"
SNELL_SERVICE="/etc/systemd/system/snellv6.service"
LOG_FILE="/var/log/snellv6_manager.log"
SNELL_USER="snellv6"

# ================== 工具函数 ==================
create_user() {
    # 建立独立的系统用户，避免权限交叉
    id -u "$SNELL_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin "$SNELL_USER"
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

random_port() {
    shuf -i 2000-65000 -n 1
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 动态获取官方最新 Snell v6 版本
get_latest_snell_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | \
        grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
        
    if [[ -z "$latest_version" ]]; then
        latest_version="v6.0.0b4"
    fi
    echo "$latest_version"
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[信息] 开始配置 Snell v6 独立服务...${RESET}"

    read -p "请输入端口 (默认: 随机生成): " input_port
    port=${input_port:-$(random_port)}
    check_port "$port" || return

    read -p "请输入 Snell 密钥 (默认: 随机生成): " key
    key=${key:-$(random_key)}

    echo -e "${YELLOW}请选择 Snell 工作模式 (mode):${RESET}"
    echo "1. default     (默认：流量混淆 + AES 加密)"
    echo "2. unshaped    (禁用混淆，仅 AES 加密。吞吐量提升约 10%，等同于 v3 纯随机流量)"
    echo "3. unsafe-raw  (明文模式：禁用加密和混淆，仅用于受信任内网/安全隧道)"
    read -p "(默认: 1): " mode_choice
    case $mode_choice in
        2) snell_mode="unshaped" ;;
        3) snell_mode="unsafe-raw" ;;
        *) snell_mode="default" ;;
    esac

    echo -e "${YELLOW}请选择监听网络模式 (Listen Mode):${RESET}"
    echo "1. 同时监听 IPv4 & IPv6 (双栈显式绑定，推荐)"
    echo "2. 仅监听 IPv4 (0.0.0.0)"
    echo "3. 仅监听 IPv6 ([::])"
    read -p "(默认: 1): " listen_choice
    listen_choice=${listen_choice:-1}
    case $listen_choice in
        2) LISTEN="0.0.0.0:$port" ;;
        3) LISTEN="[::]:$port" ;;
        *) LISTEN="0.0.0.0:$port,[::]:$port" ;;
    esac

    echo -e "${YELLOW}请选择 DNS 解析 IP 家族优先级 (dns-ip-preference):${RESET}"
    echo "1. default      (系统默认)"
    echo "2. prefer-ipv4  (IPv4 优先)"
    echo "3. prefer-ipv6  (IPv6 优先)"
    echo "4. ipv4-only    (仅使用 IPv4)"
    echo "5. ipv6-only    (仅使用 IPv6)"
    read -p "(默认: 1): " dns_pref_choice
    case $dns_pref_choice in
        2) dns_pref="prefer-ipv4" ;;
        3) dns_pref="prefer-ipv6" ;;
        4) dns_pref="ipv4-only" ;;
        5) dns_pref="ipv6-only" ;;
        *) dns_pref="default" ;;
    esac

    echo -e "${YELLOW}配置 OBFS：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    read -p "(默认: 3): " obfs
    case $obfs in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        *) obfs="off" ;;
    esac

    echo -e "${YELLOW}是否开启 TCP Fast Open？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 1): " tfo
    tfo=${tfo:-1}
    tfo=$([ "$tfo" = "1" ] && echo true || echo false)

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入上游 DNS (默认: $default_dns): " dns
    dns=${dns:-$default_dns}

    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $LISTEN
psk = $key
mode = $snell_mode
obfs = $obfs
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    cat <<EOF > "$SNELL_DIR/config.txt"
$HOSTNAME-SnellV6 = snell, $IP, $port, psk=$key, version=6, mode=$snell_mode, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
    echo -e "${GREEN}====== Snell v6 Server 配置信息 ======${RESET}"
    echo -e "${YELLOW} 绑定地址 (Listen) : $LISTEN${RESET}"
    echo -e "${YELLOW} 密钥 (PSK)        : $key${RESET}"
    echo -e "${YELLOW} 工作模式 (Mode)   : $snell_mode${RESET}"
    echo -e "${YELLOW} OBFS 混淆         : $obfs${RESET}"
    echo -e "${YELLOW} TFO 快速打开      : $tfo${RESET}"
    echo -e "${YELLOW} DNS 上游          : $dns${RESET}"
    echo -e "${YELLOW} DNS 家族优先级    : $dns_pref${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置示例：${RESET}"
    cat "$SNELL_DIR/config.txt"
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

# ================== 修改配置 Snell ==================
configures_snell() {
    echo -e "${GREEN}[信息] 开始修改 Snell v6 配置...${RESET}"

    if [[ -f "$SNELL_CONFIG" ]]; then
        old_listen=$(grep '^listen' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_port=$(echo "$old_listen" | awk -F: '{print $NF}')
        old_key=$(grep '^psk' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_mode=$(grep '^mode' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_obfs=$(grep '^obfs' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_tfo=$(grep '^tfo' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns=$(grep '^dns' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns_pref=$(grep '^dns-ip-preference' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
    fi

    default_port=${old_port:-$(random_port)}
    default_key=${old_key:-$(random_key)}
    default_mode=${old_mode:-default}
    default_obfs=${old_obfs:-off}
    default_tfo=${old_tfo:-true}
    default_dns_pref=${old_dns_pref:-default}
    
    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    default_dns=${old_dns:-$default_dns}

    read -p "请输入端口 [当前: $default_port]: " input_port
    port=${input_port:-$default_port}
    if [[ "$port" != "$old_port" ]]; then
        check_port "$port" || return
    fi

    read -p "请输入 Snell 密钥 [当前: $default_key]: " key
    key=${key:-$default_key}

    echo -e "${YELLOW}请选择 Snell 工作模式 [当前: $default_mode]:${RESET}"
    echo "1. default    2. unshaped    3. unsafe-raw"
    read -p "(直接回车保留当前): " mode_choice
    case $mode_choice in
        1) snell_mode="default" ;;
        2) snell_mode="unshaped" ;;
        3) snell_mode="unsafe-raw" ;;
        *) snell_mode="$default_mode" ;;
    esac

    echo -e "${YELLOW}请选择监听网络模式 (当前: $old_listen):${RESET}"
    echo "1. 同时监听 IPv4 & IPv6 (双栈绑定)"
    echo "2. 仅监听 IPv4"
    echo "3. 仅监听 IPv6"
    read -p "(直接回车保留当前): " listen_choice
    case $listen_choice in
        1) LISTEN="0.0.0.0:$port,[::]:$port" ;;
        2) LISTEN="0.0.0.0:$port" ;;
        3) LISTEN="[::]:$port" ;;
        *) LISTEN=${old_listen:-"0.0.0.0:$port,[::]:$port"} ;;
    esac

    echo -e "${YELLOW}请选择 DNS 解析 IP 家族优先级 (当前: $default_dns_pref):${RESET}"
    echo "1. default    2. prefer-ipv4    3. prefer-ipv6    4. ipv4-only    5. ipv6-only"
    read -p "(直接回车保留当前): " dns_pref_choice
    case $dns_pref_choice in
        1) dns_pref="default" ;;
        2) dns_pref="prefer-ipv4" ;;
        3) dns_pref="prefer-ipv6" ;;
        4) dns_pref="ipv4-only" ;;
        5) dns_pref="ipv6-only" ;;
        *) dns_pref="$default_dns_pref" ;;
    esac

    echo -e "${YELLOW}配置 OBFS [当前: $default_obfs]:${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    read -p "(直接回车保留当前): " obfs_choice
    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        3) obfs="off" ;;
        *) obfs="$default_obfs" ;;
    esac

    echo -e "${YELLOW}是否开启 TCP Fast Open？[当前: $default_tfo]${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(直接回车保留当前): " tfo_choice
    case $tfo_choice in
        1) tfo=true ;;
        2) tfo=false ;;
        *) tfo="$default_tfo" ;;
    esac

    read -p "请输入 DNS [当前: $default_dns]: " dns
    dns=${dns:-$default_dns}

    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $LISTEN
psk = $key
mode = $snell_mode
obfs = $obfs
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    cat > "$SNELL_DIR/config.txt" <<EOF
$HOSTNAME-SnellV6 = snell, $IP, $port, psk=$key, version=6, mode=$snell_mode, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已保存${RESET}"
}

# ================== 下载与解压内核 ==================
download_and_extract_snell() {
    local RAW_VERSION=$1
    local ARCH
    ARCH=$(uname -m)
    
    if ! command -v unzip &>/dev/null; then
        echo -e "${YELLOW}[提示] 未检测到 unzip，正在安装...${RESET}"
        if command -v apt &>/dev/null; then apt update && apt install -y unzip;
        elif command -v yum &>/dev/null; then yum install -y unzip;
        elif command -v apk &>/dev/null; then apk add unzip; fi
    fi

    local URL_ARCH
    case "$ARCH" in
        aarch64|arm64)              URL_ARCH="linux-aarch64" ;;
        armv7l|armhf|armv8l)        URL_ARCH="linux-armv7l" ;;
        x86_64|amd64)               URL_ARCH="linux-amd64" ;;
        i386|i686|x86)              URL_ARCH="linux-i386" ;;
        *) echo -e "${RED}[错误] 不支持的架构: ${ARCH}${RESET}"; return 1 ;;
    esac

    local VERSION_WITHOUT_V="${RAW_VERSION#v}"
    local VERSION_WITH_V="v${VERSION_WITHOUT_V}"

    local URLS=(
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITH_V}-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}b4-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-v${VERSION_WITHOUT_V}b4-${URL_ARCH}.zip"
    )

    local success=false
    for url in "${URLS[@]}"; do
        echo -e "${GREEN}[信息] 尝试从路径下载: ${url}${RESET}"
        if wget --spider -q -T 5 "$url"; then
            if wget -O snell.zip "$url"; then
                success=true
                break
            fi
        fi
    done

    if [ "$success" = false ]; then
        echo -e "${YELLOW}[提示] 动态版本下载失败，尝试使用已知稳定的 v6.0.0b4 保底下载...${RESET}"
        local FALLBACK_URL="https://dl.nssurge.com/snell/snell-server-v6.0.0b4-${URL_ARCH}.zip"
        if wget -O snell.zip "$FALLBACK_URL"; then
            success=true
        fi
    fi

    if [ "$success" = false ]; then
        echo -e "${RED}[错误] 无法连接到官方下载服务器，请检查网络。${RESET}"
        return 1
    fi

    unzip -o snell.zip -d "$SNELL_DIR"
    rm -f snell.zip
    chmod +x "$SNELL_DIR/snell-server"
}

# ================== 安装 Snell ==================
install_snell() {
    echo -e "${GREEN}[信息] 正在获取官方最新版本号...${RESET}"
    local VERSION
    VERSION=$(get_latest_snell_version)
    echo -e "${GREEN}[信息] 检测到官方最新版本号为: ${VERSION}${RESET}"

    create_user
    mkdir -p "$SNELL_DIR"
    cd "$SNELL_DIR"

    download_and_extract_snell "$VERSION" || return
    configure_snell

    cat > "$SNELL_SERVICE" <<EOF
[Unit]
Description=Snell v6 Independent Server
After=network.target

[Service]
ExecStart=$SNELL_DIR/snell-server -c $SNELL_CONFIG
Restart=on-failure
User=$SNELL_USER
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snellv6
    systemctl start snellv6
    echo -e "${GREEN}[完成] Snell v6 独立服务已成功安装并启动！${RESET}"
    log "Snell v6 已安装并启动 (${VERSION})"
}

# ================== 更新 Snell ==================
update_snell() {
    if [ ! -f "$SNELL_CONFIG" ]; then
        echo -e "${RED}未找到配置文件，无法更新${RESET}"
        return
    fi

    echo -e "${GREEN}[信息] 正在获取官方最新版本号...${RESET}"
    local VERSION
    VERSION=$(get_latest_snell_version)
    echo -e "${GREEN}[信息] 检测到官方最新版本为: ${VERSION}${RESET}"

    systemctl stop snellv6 || true
    cd "$SNELL_DIR"

    download_and_extract_snell "$VERSION" || return
    systemctl restart snellv6

    echo -e "${GREEN}[完成] Snell v6 已更新至 ${VERSION}${RESET}"
    log "Snell v6 已更新 (${VERSION})"
}

# ================== 卸载 Snell ==================
uninstall_snell() {
    echo -e "${RED}[警告] 正在彻底卸载 Snell v6 独立服务...${RESET}"
    systemctl stop snellv6 || true
    systemctl disable snellv6 || true
    rm -f "$SNELL_SERVICE"
    rm -rf "$SNELL_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] Snell v6 已卸载${RESET}"
    log "Snell v6 已卸载"
}

# ================== 菜单面版 ==================
show_menu() {
    clear
    if systemctl is-active --quiet snellv6; then
        STATUS="${GREEN}● 运行中${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    VERSION_SHOW="未安装"
    if [ -x "$SNELL_DIR/snell-server" ]; then
        VERSION_SHOW=$("$SNELL_DIR/snell-server" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?')
        [ -z "$VERSION_SHOW" ] && VERSION_SHOW=$("$SNELL_DIR/snell-server" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?')
        [ -z "$VERSION_SHOW" ] && VERSION_SHOW="未知版本"
    fi

    LISTEN_SHOW="-"
    if [ -f "$SNELL_CONFIG" ]; then
        LISTEN_SHOW=$(grep '^listen' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈   Snell v6 管理面板   ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}绑定   :${RESET} ${YELLOW}$LISTEN_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v6${RESET}"
    echo -e "${GREEN}2. 更新 Snell v6${RESET}"
    echo -e "${GREEN}3. 卸载 Snell v6${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell v6${RESET}"
    echo -e "${GREEN}6. 停止 Snell v6${RESET}"
    echo -e "${GREEN}7. 重启 Snell v6${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    case $choice in
        1) install_snell; pause ;;
        2) update_snell; pause ;;
        3) uninstall_snell; pause ;;
        4) configures_snell; systemctl restart snellv6; pause ;;
        5) systemctl start snellv6; echo -e "${GREEN}[完成] 已启动${RESET}"; pause ;;
        6) systemctl stop snellv6; echo -e "${GREEN}[完成] 已停止${RESET}"; pause ;;
        7) systemctl restart snellv6; echo -e "${GREEN}[完成] 已重启${RESET}"; pause ;;
        8) journalctl -u snellv6 -e --no-pager; pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== Snell v6 内部配置文件 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 节点配置单行 ======${RESET}"
                cat "$SNELL_DIR/config.txt"
            else
                echo -e "${RED}配置文件不存在${RESET}"
            fi
            pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
