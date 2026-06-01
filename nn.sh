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
STLS_DIR="/etc/shadow-tls"
STLS_SERVICE="/etc/systemd/system/shadow-tls.service"
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

get_latest_snell_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" | \
        grep -oE 'v5\.[0-9]+\.[0-9]+' | head -n 1 2>/dev/null || echo "")
        
    if [[ -z "$latest_version" ]]; then
        latest_version="v5.0.1"
    fi
    echo "$latest_version"
}

get_latest_stls_version() {
    local latest_version
    latest_version=$(curl -s -m 10 https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$latest_version" ]]; then
        latest_version="v0.2.25" # 兜底稳定版
    fi
    echo "$latest_version"
}

# ================== 配置 Snell & Shadow-TLS ==================
configure_snell() {
    echo -e "${GREEN}[信息]开始配置 Snell...${RESET}"

    # ===== 1. Snell 本地内部端口 =====
    echo -e "${YELLOW}提示: 启用 Shadow-TLS 后，Snell 端口仅在本地监听，外部无法直接连接该端口${RESET}"
    read -p "请输入 Snell 内部端口 (默认: 随机生成): " input_snell_port
    snell_port=${input_snell_port:-$(shuf -i 30000-60000 -n1)}
    check_port "$snell_port" || return

    # ===== 2. Shadow-TLS 外部公网端口 =====
    read -p "请输入 Shadow-TLS 外部监听端口 (默认: 443): " input_stls_port
    stls_port=${input_stls_port:-443}
    check_port "$stls_port" || return

    read -p "请输入 Snell 密钥 (默认: 随机生成): " key
    key=${key:-$(random_key)}

    # ===== 3. Shadow-TLS 专属配置 =====
    read -p "请输入 Shadow-TLS 密码 (默认: 随机生成): " stls_password
    stls_password=${stls_password:-$(random_key)}

    read -p "请输入 Shadow-TLS 伪装 SNI 域名 (默认: gateway.icloud.com): " stls_sni
    stls_sni=${stls_sni:-"gateway.icloud.com"}

    echo -e "${YELLOW}是否开启 IPv6 解析？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 2): " ipv6
    ipv6=${ipv6:-2}
    ipv6=$([ "$ipv6" = "1" ] && echo true || echo false)

    echo -e "${YELLOW}是否开启 TCP Fast Open？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 1): " tfo
    tfo=${tfo:-1}
    tfo=$([ "$tfo" = "1" ] && echo true || echo false)

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入 DNS (默认: $default_dns): " dns
    dns=${dns:-$default_dns}

    # Snell 此时只监听本地环回地址，由 Shadow-TLS 转发流量，更安全
    LISTEN="127.0.0.1:$snell_port"

    cat > $SNELL_CONFIG <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = off
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    # 写入 Shadow-TLS 的环境变量或参数文件
    mkdir -p $STLS_DIR
    cat > $STLS_DIR/env <<EOF
STLS_LISTEN=0.0.0.0:$stls_port
STLS_SERVER=127.0.0.1:$snell_port
STLS_PASSWORD=$stls_password
STLS_SNI=$stls_sni
EOF

    # 获取公网 IP
    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    # 生成包含 Shadow-TLS 的 Surge 配置
    cat <<EOF > $SNELL_DIR/config.txt
$HOSTNAME-Snell-TLS = snell, $IP, $stls_port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true, shadow-tls-password=$stls_password, shadow-tls-sni=$stls_sni, shadow-tls-v3=true
EOF

    echo -e "${GREEN}[完成] 配置已写入完成${RESET}"
    echo -e "${GREEN}====== Snell + Shadow-TLS 配置信息 ======${RESET}"
    echo -e "${YELLOW} 公网 IP 地址   : $IP${RESET}"
    echo -e "${YELLOW} 外部监听端口   : $stls_port (Shadow-TLS)${RESET}"
    echo -e "${YELLOW} Snell 内部端口 : $snell_port (仅本地本地)${RESET}"
    echo -e "${YELLOW} Snell PSK 密钥 : $key${RESET}"
    echo -e "${YELLOW} TLS 密码 (pwd) : $stls_password${RESET}"
    echo -e "${YELLOW} 伪装 SNI 域名  : $stls_sni${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}[信息] Surge 5 配置示例：${RESET}"
    cat $SNELL_DIR/config.txt
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

# ================== 修改配置 ==================
configures_snell() {
    echo -e "${GREEN}[信息]开始修改配置...${RESET}"

    # 读取旧配置
    local old_snell_port old_key old_ipv6 old_txo old_dns old_stls_port old_stls_password old_stls_sni
    if [[ -f "$SNELL_CONFIG" ]]; then
        old_listen=$(grep '^listen' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_snell_port=$(echo "$old_listen" | awk -F: '{print $NF}')
        old_key=$(grep '^psk' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_ipv6=$(grep '^ipv6' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_tfo=$(grep '^tfo' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns=$(grep '^dns' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
    fi
    if [[ -f "$STLS_DIR/env" ]]; then
        old_stls_port=$(grep '^STLS_LISTEN' "$STLS_DIR/env" | awk -F: '{print $NF}')
        old_stls_password=$(grep '^STLS_PASSWORD' "$STLS_DIR/env" | awk -F'=' '{print $2}')
        old_stls_sni=$(grep '^STLS_SNI' "$STLS_DIR/env" | awk -F'=' '{print $2}')
    fi

    default_snell_port=${old_snell_port:-$(random_port)}
    default_stls_port=${old_stls_port:-443}
    default_key=${old_key:-$(random_key)}
    default_stls_pwd=${old_stls_password:-$(random_key)}
    default_stls_sni=${old_stls_sni:-"gateway.icloud.com"}
    default_ipv6=${old_ipv6:-false}
    default_tfo=${old_tfo:-true}

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    default_dns=${old_dns:-$default_dns}

    read -p "请输入 Snell 内部端口 [当前:$default_snell_port]: " input_snell_port
    snell_port=${input_snell_port:-$default_snell_port}

    read -p "请输入 Shadow-TLS 外部端口 [当前:$default_stls_port]: " input_stls_port
    stls_port=${input_stls_port:-$default_stls_port}

    read -p "请输入 Snell 密钥 [当前:$default_key]: " key
    key=${key:-$default_key}

    read -p "请输入 Shadow-TLS 密码 [当前:$default_stls_pwd]: " stls_password
    stls_password=${stls_password:-$default_stls_pwd}

    read -p "请输入 Shadow-TLS SNI [当前:$default_stls_sni]: " stls_sni
    stls_sni=${stls_sni:-$default_stls_sni}

    # DNS & TFO 保留默认或跟随原本环境
    dns=$default_dns
    ipv6=$default_ipv6
    tfo=$default_tfo

    # 写入配置
    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = 127.0.0.1:$snell_port
psk = $key
obfs = off
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    mkdir -p $STLS_DIR
    cat > $STLS_DIR/env <<EOF
STLS_LISTEN=0.0.0.0:$stls_port
STLS_SERVER=127.0.0.1:$snell_port
STLS_PASSWORD=$stls_password
STLS_SNI=$stls_sni
EOF

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    cat > "$SNELL_DIR/config.txt" <<EOF
$HOSTNAME-Snell-TLS = snell, $IP, $stls_port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true, shadow-tls-password=$stls_password, shadow-tls-sni=$stls_sni, shadow-tls-v3=true
EOF

    echo -e "${GREEN}[完成] 配置已保存，请手动或通过菜单重启服务生效${RESET}"
}

# ================== 安装 Snell & Shadow-TLS ==================
install_snell() {
    # 1. 获取最新 Snell 版本并下载
    echo -e "${GREEN}[信息] 正在获取官方最新 Snell 版本号...${RESET}"
    local VERSION STLS_VERSION ARCH
    VERSION=$(get_latest_snell_version)
    echo -e "${GREEN}[信息] 检测到 Snell 最新版本为: ${VERSION}${RESET}"

    create_user
    mkdir -p $SNELL_DIR
    cd $SNELL_DIR

    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
        STLS_URL_SUFFIX="aarch64-unknown-linux-musl"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
        STLS_URL_SUFFIX="x86_64-unknown-linux-musl"
    fi

    wget -O snell.zip "$SNELL_URL"
    unzip -o snell.zip -d $SNELL_DIR
    rm -f snell.zip
    chmod +x $SNELL_DIR/snell-server

    # 2. 获取并下载 Shadow-TLS
    echo -e "${GREEN}[信息] 正在获取 Shadow-TLS 最新版本号...${RESET}"
    STLS_VERSION=$(get_latest_stls_version)
    echo -e "${GREEN}[信息] 检测到 Shadow-TLS 最新版本为: ${STLS_VERSION}${RESET}"

    mkdir -p $STLS_DIR
    cd $STLS_DIR
    wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_URL_SUFFIX}"
    chmod +x shadow-tls

    # 3. 运行交互配置
    configure_snell

    # 4. 写入 Snell Systemd 脚本
    cat > $SNELL_SERVICE <<EOF
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

    # 5. 写入 Shadow-TLS Systemd 脚本
    cat > $STLS_SERVICE <<EOF
[Unit]
Description=Shadow-TLS Server
After=network.target snell.service

[Service]
Type=simple
EnvironmentFile=$STLS_DIR/env
ExecStart=$STLS_DIR/shadow-tls --password \$STLS_PASSWORD server --listen \$STLS_LISTEN --server \$STLS_SERVER --sni \$STLS_SNI v3
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell shadow-tls
    systemctl start snell shadow-tls
    echo -e "${GREEN}[完成] Snell 与 Shadow-TLS 已成功安装并启动！${RESET}"
    log "Snell ($VERSION) & Shadow-TLS ($STLS_VERSION) 已同步启动。"
}

# ================== 更新 Snell & Shadow-TLS ==================
update_snell() {
    echo -e "${GREEN}[信息] 正在检测更新...${RESET}"
    systemctl stop shadow-tls snell || true

    local VERSION STLS_VERSION ARCH
    ARCH=$(uname -m)
    
    # 更新 Snell
    if [ -d "$SNELL_DIR" ]; then
        VERSION=$(get_latest_snell_version)
        cd $SNELL_DIR
        if [[ "$ARCH" == "aarch64" ]]; then
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
        else
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
        fi
        wget -O snell.zip "$SNELL_URL" && unzip -o snell.zip -d $SNELL_DIR && rm -f snell.zip
        chmod +x snell-server
        echo -e "${GREEN}[完成] Snell 更新完成 (${VERSION})${RESET}"
    fi

    # 更新 Shadow-TLS
    if [ -d "$STLS_DIR" ]; then
        STLS_VERSION=$(get_latest_stls_version)
        cd $STLS_DIR
        if [[ "$ARCH" == "aarch64" ]]; then
            STLS_URL_SUFFIX="aarch64-unknown-linux-musl"
        else
            STLS_URL_SUFFIX="x86_64-unknown-linux-musl"
        fi
        wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_URL_SUFFIX}"
        chmod +x shadow-tls
        echo -e "${GREEN}[完成] Shadow-TLS 更新完成 (${STLS_VERSION})${RESET}"
    fi

    systemctl start snell shadow-tls
    log "组件已执行一键更新操作。"
}

# ================== 卸载 ==================
uninstall_snell() {
    echo -e "${RED}[警告] 正在全套卸载 Snell 与 Shadow-TLS...${RESET}"
    systemctl stop shadow-tls snell || true
    systemctl disable shadow-tls snell || true
    rm -f $SNELL_SERVICE $STLS_SERVICE
    rm -rf $SNELL_DIR $STLS_DIR
    systemctl daemon-reload
    echo -e "${GREEN}[完成] 卸载完毕${RESET}"
    log "Snell 与 Shadow-TLS 已完全卸载"
}

# ================== 菜单展示 ==================
show_menu() {
    clear
    # ===== 运行状态检测 =====
    if systemctl is-active --quiet snell && systemctl is-active --quiet shadow-tls; then
        STATUS="${GREEN}● 运行中 (Snell + TLS)${RESET}"
    elif systemctl is-active --quiet snell; then
        STATUS="${YELLOW}▲ 仅 Snell 运行中 (TLS 未启动)${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    # ===== 获取版本 =====
    VERSION_SHOW="未安装"
    if [ -x "$SNELL_DIR/snell-server" ]; then
        VERSION_SHOW=$("$SNELL_DIR/snell-server" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "v5.x")
    fi
    
    STLS_SHOW="未安装"
    if [ -x "$STLS_DIR/shadow-tls" ]; then
        STLS_SHOW=$("$STLS_DIR/shadow-tls" --version 2>&1 | awk '{print $2}' || echo "已安装")
    fi

    # ===== 端口展示 =====
    PORT_SHOW="-"
    if [ -f "$STLS_DIR/env" ]; then
        PORT_SHOW=$(grep '^STLS_LISTEN' "$STLS_DIR/env" | awk -F: '{print $NF}')
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Snell + Shadow-TLS 面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}系统状态 :${RESET} $STATUS"
    echo -e "${GREEN}Snell    :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}Shdw-TLS :${RESET} ${YELLOW}$STLS_SHOW${RESET}"
    echo -e "${GREEN}公网端口 :${RESET} ${YELLOW}$PORT_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}1. 安装 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}2. 一键更新所有组件${RESET}"
    echo -e "${GREEN}3. 卸载所有组件${RESET}"
    echo -e "${GREEN}4. 修改配置 (端口/密码/SNI)${RESET}"
    echo -e "${GREEN}5. 启动服务${RESET}"
    echo -e "${GREEN}6. 停止服务${RESET}"
    echo -e "${GREEN}7. 重启服务${RESET}"
    echo -e "${GREEN}8. 查看 Shadow-TLS 日志${RESET}"
    echo -e "${GREEN}9. 查看 Surge 节点配置${RESET}"
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
        4) configures_snell; systemctl restart snell shadow-tls; pause ;;
        5) systemctl start snell shadow-tls; echo -e "${GREEN}[完成] 服务已启动${RESET}"; pause ;;
        6) systemctl stop shadow-tls snell; echo -e "${GREEN}[完成] 服务已停止${RESET}"; pause ;;
        7) systemctl restart snell shadow-tls; echo -e "${GREEN}[完成] 服务已重启${RESET}"; pause ;;
        8) journalctl -u shadow-tls -e --no-pager; pause ;;
        9)
            if [ -f "$SNELL_DIR/config.txt" ]; then
                echo -e "${GREEN}====== Surge 5 节点配置 ======${RESET}"
                cat "$SNELL_DIR/config.txt"
                echo -e "${YELLOW}提示: 如果你使用的是外部 TLS 端口(例如443)，请确保防火墙已放行。${RESET}"
            else
                echo -e "${RED}配置不存在，请先安装。${RESET}"
            fi
            pause
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
