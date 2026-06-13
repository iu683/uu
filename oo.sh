#!/bin/bash
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell.service"
LOG_FILE="/var/log/snell_manager.log"

# ================== 工具函数 ==================
create_user() {
    id -u snell &>/dev/null || useradd -r -s /usr/sbin/nologin snell
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
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
        latest_version="v6.0.0b2"
    fi
    echo "$latest_version"
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[信息] 开始配置 Snell (v6 协议栈增强版)...${RESET}"

    read -p "请输入端口 (默认: 随机生成): " input_port
    port=${input_port:-$(random_port)}
    check_port "$port" || return

    read -p "请输入 Snell 密钥 (默认: 随机生成): " key
    key=${key:-$(random_key)}

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
obfs = $obfs
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    cat <<EOF > "$SNELL_DIR/config.txt"
$HOSTNAME-Snell = snell, $IP, $port, psk=$key, version=6, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
    echo -e "${GREEN}====== Snell Server 配置信息 ======${RESET}"
    echo -e "${YELLOW} 绑定地址 (Listen) : $LISTEN${RESET}"
    echo -e "${YELLOW} 密钥 (PSK)        : $key${RESET}"
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
    echo -e "${GREEN}[信息] 开始修改 Snell 配置...${RESET}"

    if [[ -f "$SNELL_CONFIG" ]]; then
        old_listen=$(grep '^listen' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_port=$(echo "$old_listen" | awk -F: '{print $NF}')
        old_key=$(grep '^psk' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_obfs=$(grep '^obfs' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_tfo=$(grep '^tfo' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns=$(grep '^dns' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns_pref=$(grep '^dns-ip-preference' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
    fi

    default_port=${old_port:-$(random_port)}
    default_key=${old_key:-$(random_key)}
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
obfs = $obfs
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    cat > "$SNELL_DIR/config.txt" <<EOF
$HOSTNAME-Snell = snell, $IP, $port, psk=$key, version=6, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已保存${RESET}"
}

# ================== 下载与解压内核 (多重智能嗅探 Fallback) ==================
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

    # 规范化架构标识
    local URL_ARCH
    case "$ARCH" in
        aarch64|arm64)              URL_ARCH="linux-aarch64" ;;
        armv7l|armhf|armv8l)        URL_ARCH="linux-armv7l" ;;
        x86_64|amd64)               URL_ARCH="linux-amd64" ;;
        i386|i686|x86)              URL_ARCH="linux-i386" ;;
        *) echo -e "${RED}[错误] 不支持的架构: ${ARCH}${RESET}"; return 1 ;;
    esac

    # 提取纯数字版本
    local VERSION_WITHOUT_V="${RAW_VERSION#v}"
    local VERSION_WITH_V="v${VERSION_WITHOUT_V}"

    # 构造多种可能存在的官方下载链接形式 (包含正式版与各种Beta变体)
    local URLS=(
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITH_V}-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}b2-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-v${VERSION_WITHOUT_V}b2-${URL_ARCH}.zip"
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
        # 终极保底兜底：如果全新 6.0.0 由于官方未上架彻底失败，则降级抓取已知的安全可用版
        echo -e "${YELLOW}[提示] 动态版本下载失败，尝试使用已知稳定的 v6.0.0b2 保底下载...${RESET}"
        local FALLBACK_URL="https://dl.nssurge.com/snell/snell-server-v6.0.0b2-${URL_ARCH}.zip"
        if wget -O snell.zip "$FALLBACK_URL"; then
            success=true
        fi
    fi

    if [ "$success" = false ]; then
        echo -e "${RED}[错误] 无法连接到官方下载服务器，或官方暂未打包此架构，请检查网络后再试。${RESET}"
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
Description=Snell Server
After=network.target

[Service]
ExecStart=$SNELL_DIR/snell-server -c $SNELL_CONFIG
Restart=on-failure
User=snell
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell
    echo -e "${GREEN}[完成] Snell 已成功安装并启动！${RESET}"
    log "Snell 已安装并启动 (${VERSION})"
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

    systemctl stop snell || true
    cd "$SNELL_DIR"

    download_and_extract_snell "$VERSION" || return
    systemctl restart snell

    echo -e "${GREEN}[完成] Snell 已更新至 ${VERSION}${RESET}"
    log "Snell 已更新 (${VERSION})"
}

# ================== 卸载 Snell ==================
uninstall_snell() {
    echo -e "${RED}[警告] 正在彻底卸载 Snell...${RESET}"
    systemctl stop snell || true
    systemctl disable snell || true
    rm -f "$SNELL_SERVICE"
    rm -rf "$SNELL_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] Snell 已完美卸载${RESET}"
    log "Snell 已卸载"
}

# ================== 菜单面版 ==================
show_menu() {
    clear
    if systemctl is-active --quiet snell; then
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
    echo -e "${GREEN}      Snell v6 管理面板 (双栈版)  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}绑定   :${RESET} ${YELLOW}$LISTEN_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell${RESET}"
    echo -e "${GREEN}2. 更新 Snell${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改网络栈及配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置 (Surge格式)${RESET}"
    echo -p "0. 退出"
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
        4) configures_snell; systemctl restart snell; pause ;;
        5) systemctl start snell; echo -e "${GREEN}[完成] 已启动${RESET}"; pause ;;
        6) systemctl stop snell; echo -e "${GREEN}[完成] 已停止${RESET}"; pause ;;
        7) systemctl restart snell; echo -e "${GREEN}[完成] 已重启${RESET}"; pause ;;
        8) journalctl -u snell -e --no-pager; pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== Snell 内部配置文件 ======${RESET}"
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
