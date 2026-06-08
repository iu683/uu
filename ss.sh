#!/usr/bin/env bash

# ==============================================================================
#  cf-warp-rust 终极全能面板 (IPv6-Only 优化、支持谷歌分流与真·全局出站)
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="Shannon-x/cf-warp-rust"
export SERVICE_NAME="warp-rust"
export SERVICE_USER="root" 
export INSTALL_BIN="/usr/local/bin/warp-rust"
export CONF_DIR="/etc/warp-rust"
export CONF_FILE="${CONF_DIR}/config.toml"
export DATA_DIR="/var/lib/warp-rust"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 【保留 10】谷歌透明代理相关变量
export REDSOCKS_CONF="/etc/redsocks.conf"
export PROXY_SERVICE_NAME="warp-google-proxy"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"
export PROXY_RULES_SCRIPT="${DATA_DIR}/warp-google-iptables.sh"

# 【新增 11】全局透明代理组件相关变量
export TUN2SOCKS_BIN="/usr/local/bin/tun2socks"
export TUN_DEV_NAME="tun_global"

# ── IPv6 友好型 GitHub 反代加速节点池 ──────────────────────────────────────────
# 经过严格筛选，这些节点均支持双栈或纯 IPv6 解析，非常适合 IPv6-Only VPS
GITHUB_PROXIES=(
    "https://v6.gh-proxy.org/"
    "https://proxy.vvvv.ee/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://hub.glowp.xyz/"
    "https://ghproxy.lvedong.eu.org/"
)

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# Google IP 段定义（用于 iptables 劫持分流）
GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

# ── 基础环境校验 ──────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os

# 基础组件检查 (针对 IPv6-only 环境优化)
REQUIRED_CMDS="curl tar sed grep awk ip pkill"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "正在自动修复系统缺失组件:${YELLOW}$MISSING_CMDS${RESET}..."
    case "$OS" in
        ubuntu|debian) apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then dnf install -y $MISSING_CMDS >/dev/null 2>&1
            else yum install -y $MISSING_CMDS >/dev/null 2>&1; fi ;;
        *) die "请手动安装基础组件: $MISSING_CMDS" ;;
    esac
fi

# ── 动态优选支持 IPv6 的 GitHub 代理节点 ────────────────────────────────────
select_best_proxy() {
    info "正在为您动态优选适合 IPv6 环境的 GitHub 加速节点..."
    local best_proxy=""
    local min_time=9999
    
    # 只检测前几个节点以节省脚本启动时间
    for proxy in "${GITHUB_PROXIES[@]}"; do
        # 强制使用 -6 (IPv6) 进行毫秒级连接测试
        local start_time
        start_time=$(date +%s%N)
        if curl -6 -sIL --connect-timeout 2 --max-time 3 "${proxy}" > /dev/null 2>&1; then
            local end_time
            end_time=$(date +%s%N)
            local duration=$(( (end_time - start_time) / 1000000 )) # 转换为毫秒
            
            if [ $duration -lt $min_time ]; then
                min_time=$duration
                best_proxy=$proxy
            fi
        fi
    done

    if [ -n "$best_proxy" ]; then
        ok "成功匹配 IPv6 最优加速源: ${GREEN}${best_proxy}${RESET} (延迟: ${min_time}ms)"
        AVAILABLE_PROXY=$best_proxy
    else
        warn "未检测到原生支持纯 IPv6 的反代节点，将尝试直接连接 GitHub..."
        AVAILABLE_PROXY=""
    fi
}

# ── 1. 核心下载与组件解压 (全面适配 IPv6 代理) ───────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl"; T2S_ARCH="amd64" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl"; T2S_ARCH="arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac
}

fetch_latest_version() {
    select_best_proxy
    info "正在查询 GitHub 获取最新 Release 版本号..."
    
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    # 如果找到了可用的反代站，走反代站请求 API
    if [ -n "$AVAILABLE_PROXY" ]; then
        api_url="${AVAILABLE_PROXY}${api_url}"
    fi

    TMP_API="$(mktemp)"
    # 强制 IPv6 兼容请求
    if curl -6 -sSL -H "Accept: application/vnd.github+json" --connect-timeout 5 "$api_url" > "$TMP_API"; then
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_API" | head -n 1)"
    fi
    rm -f "$TMP_API"
    
    if [ -z "$VERSION" ]; then
        local fallback_url="https://github.com/${REPO}/releases/latest"
        if [ -n "$AVAILABLE_PROXY" ]; then fallback_url="${AVAILABLE_PROXY}${fallback_url}"; fi
        VERSION=$(curl -6 -sS --connect-timeout 5 "$fallback_url" 2>/dev/null | grep -o 'tag/[vV]*[0-9.]*' | awk -F '/' 'NR==1 {print $2}')
    fi
    
    [ -z "$VERSION" ] && die "无法获取最新版本号，请检查本地 IPv6 网络连通性或代理节点状态。"
    export VERSION
}

download_and_extract() {
    detect_target
    fetch_latest_version
    info "正在匹配系统环境形态: ${YELLOW}${TARGET}${RESET}"

    ASSET="warp-rust-${VERSION}-${TARGET}.tar.gz"
    local url_tgz="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
    
    # 注入反代链
    if [ -n "$AVAILABLE_PROXY" ]; then
        url_tgz="${AVAILABLE_PROXY}${url_tgz}"
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    info "开始同步下载资产包..."
    curl -6 -fsSL --connect-timeout 10 -o "$TMP/$ASSET" "$url_tgz" || die "下载资产包失败！"

    tar xzf "$TMP/$ASSET" -C "$TMP"
    EXTRACTED_BIN=$(find "$TMP" -type f -name "warp-rust" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "在归档包内未找到 warp-rust 主程序！"
    export TARGET_BIN_PATH="$EXTRACTED_BIN"
}

# ── 2. 配置文件与纯正策略路由 Systemd 生成 ──────────────────────────────────
write_config() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    [ -d "$CONF_DIR" ] || install -m 0755 -d "$CONF_DIR"
    
    cat <<EOF > "$CONF_FILE"
[server]
bind = "${bind_ip}:${bind_port}"
EOF
    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$CONF_FILE"

[server.auth]
username = "${username}"
password = "${password}"
EOF
    fi
    cat <<EOF >> "$CONF_FILE"

[logging]
level = "warn,warp_rust=info,wireguard_netstack=warn"
format = "pretty"

[warp]
data_dir = "${DATA_DIR}"
device_model = "warp-rust"
refresh_interval = "24h"
register_cooldown = "10m"
mtu = 1420
tcp_buffer_size = 1048576

[health]
interval = "30s"
timeout = "8s"

[recovery]
reconnect_after         = 1
rebuild_config_after   = 3
reregister_after       = 5
rotate_identity_after  = 10
backoff_min = "500ms"
backoff_max = "30s"

[metrics]
enabled = true
bind = "127.0.0.1:9090"

[hot_reload]
enabled = true

[limits]
max_concurrent_connections = 1024
handshake_timeout = "10s"
idle_timeout = "300s"
relay_buffer_size = 262144
auth_fail_sleep = "1s"
relay_close_grace = "500ms"

[dns]
mode = "system"
servers = ["2606:4700:4700::1111", "1.1.1.1:53"] # 加入了 IPv6 DNS 优先
timeout = "3s"
cache_ttl = "60s"
EOF
}

write_systemd() {
    local use_global_tun="$1"
    
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=cf-warp-rust Cloudflare WARP Proxy Client
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=65535
EOF

    # 如果开启了【11】选项的全局路由劫持模式，强行缝合 tun2socks 与双栈策略路由命令
    if [ "$use_global_tun" = "true" ]; then
        local current_bind
        current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
        local warp_port="${current_bind##*:}"
        [ -z "$warp_port" ] && warp_port="1080"

        cat <<EOF >> "$SERVICE_FILE"
# ─── 策略路由网络层全局劫持 (IPv4 + IPv6 双栈全面托管) ───
ExecStartPost=/bin/sleep 2
ExecStartPost=/usr/bin/bash -c "${TUN2SOCKS_BIN} -device ${TUN_DEV_NAME} -proxy socks5://127.0.0.1:${warp_port} > /dev/null 2>&1 &"
ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/ip link set dev ${TUN_DEV_NAME} up
# IPv4 路由表
ExecStartPost=/sbin/ip route add default dev ${TUN_DEV_NAME} table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16
# IPv6 路由表 (解决 IPv6-only VPS 的全局托管需求)
ExecStartPost=/sbin/ip -6 route add default dev ${TUN_DEV_NAME} table 20
ExecStartPost=/sbin/ip -6 rule add lookup 20 pref 20
ExecStartPost=/sbin/ip -6 rule add to ::1 lookup main pref 16
ExecStartPost=/sbin/ip -6 rule add to fe80::/10 lookup main pref 16

# ─── 善后卸载还原（防止 VPS 彻底断网） ───
ExecStop=/sbin/ip rule del lookup 20 pref 20 2>/dev/null || true
ExecStop=/sbin/ip route del default dev ${TUN_DEV_NAME} table 20 2>/dev/null || true
ExecStop=/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
ExecStop=/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
ExecStop=/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
ExecStop=/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
ExecStop=/sbin/ip -6 rule del lookup 20 pref 20 2>/dev/null || true
ExecStop=/sbin/ip -6 route del default dev ${TUN_DEV_NAME} table 20 2>/dev/null || true
ExecStop=/sbin/ip -6 rule del to ::1 lookup main pref 16 2>/dev/null || true
ExecStop=/sbin/ip -6 rule del to fe80::/10 lookup main pref 16 2>/dev/null || true
ExecStopPost=/usr/bin/pkill -f tun2socks
EOF
    fi

    cat <<EOF >> "$SERVICE_FILE"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# ── 3. 保留功能：谷歌透明代理控制中心 (原本的菜单10) ───────────────────────────
start_transparent_proxy() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明分流代理已经处于运行状态，无需重复启动。"
        return
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "核心 WARP-Rust 未在后台运行！请先开启主服务。"
        return
    fi
    if [ -f "$SERVICE_FILE" ] && grep -q "tun2socks" "$SERVICE_FILE"; then
        warn "检测到当前已开启 [11.全局出站代理]，无需且不能与谷歌分流同时开启！"
        return
    fi

    local current_bind
    current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local warp_ip="${current_bind%%:*}" local warp_port="${current_bind##*:}"
    [ -z "$warp_port" ] && warp_port="1080"
    [ -z "$warp_ip" ] && warp_ip="127.0.0.1"

    info "正在检查并安装透明代理核心组件 (redsocks / iptables)..."
    local proxy_missing=""
    if ! command -v redsocks &>/dev/null; then proxy_missing="$proxy_missing redsocks"; fi
    if ! command -v iptables &>/dev/null; then proxy_missing="$proxy_missing iptables"; fi

    if [ -n "$proxy_missing" ]; then
        info "正在为系统补齐透明分流组件群:${YELLOW}$proxy_missing${RESET}..."
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y $proxy_missing >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then dnf install -y $proxy_missing >/dev/null 2>&1
                else yum install -y $proxy_missing >/dev/null 2>&1; fi ;;
        esac
    fi

    cat <<EOF > "$REDSOCKS_CONF"
base {
    log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port}; type = socks5;
}
EOF

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19"
if [ "$ACTION" = "start" ]; then
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do
        /sbin/iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    /sbin/iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || /sbin/iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    cat <<EOF > "$PROXY_SERVICE_FILE"
[Unit]
Description=Cloudflare WARP Google Transparent Proxy
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c ${REDSOCKS_CONF}
ExecStartPost=${PROXY_RULES_SCRIPT} start
ExecStop=${PROXY_RULES_SCRIPT} stop
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl start "$PROXY_SERVICE_NAME"
    ok "Google 透明分流代理已挂载！"
}

stop_transparent_proxy() {
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    ok "Google 透明代理已关闭。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 谷歌分流链路深度验证 =========${RESET}"
    if iptables -t nat -L OUTPUT -n | grep -q "WARP_GOOGLE"; then
        echo -e "   iptables 拦截链: ${GREEN}✔ 正常挂载${RESET}"
    else
        echo -e "   iptables 拦截链: ${RED}✘ 未挂载${RESET}"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then proxy_status="${YELLOW}运行中${RESET}"; fi
        echo -e "${GREEN}10. 谷歌WARP分流管理 (原iptables方案)${RESET}\n状态: $proxy_status\n1. 开启\n2. 关闭\n3. 验证\n0. 返回"
        read -r -p "选择: " sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) stop_transparent_proxy ;;
            3) verify_transparent_proxy ;;
            *) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ── 4. 新增功能：真实全局透明代理控制中心 (全新菜单11 - 支持 IPv6 依赖下载) ───────────────────────
start_global_tun_proxy() {
    if [ -f "$SERVICE_FILE" ] && grep -q "tun2socks" "$SERVICE_FILE"; then
        warn "全局透明出站已处于配置激活状态。"
        return
    fi
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "请先去菜单10关闭谷歌分流！"
        return
    fi

    if [ ! -f "$TUN2SOCKS_BIN" ]; then
        info "正在通过选定的 IPv6 友好源下载网卡接管组件 tun2socks..."
        select_best_proxy
        detect_target
        local t2s_url="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-${T2S_ARCH}"
        if [ -n "$AVAILABLE_PROXY" ]; then t2s_url="${AVAILABLE_PROXY}${t2s_url}"; fi
        
        curl -6 -fsSL --connect-timeout 10 -o "$TUN2SOCKS_BIN" "$t2s_url" || die "下载 tun2socks 失败，请检查 IPv6 网络！"
        chmod +x "$TUN2SOCKS_BIN"
        ok "tun2socks 组件部署成功。"
    fi

    info "正在重构 Systemd 全局接管路由系统..."
    write_config "127.0.0.1" "1080" "" ""
    write_systemd "true"

    systemctl restart "$SERVICE_NAME"
    sleep 3
    ok "真·双栈全局出站透明代理已彻底成功挂载！"
}

stop_global_tun_proxy() {
    if [ ! -f "$SERVICE_FILE" ] || ! grep -q "tun2socks" "$SERVICE_FILE"; then return; fi
    write_systemd "false"
    systemctl restart "$SERVICE_NAME"
    ok "全局透明出站安全卸载完毕。"
}

verify_global_tun_proxy() {
    echo -e "\n${CYAN}========= 全局网络链路深度验证 =========${RESET}"
    if ip rule show | grep -q "lookup 20" || ip -6 rule show | grep -q "lookup 20"; then
        echo -e "   策略路由双栈全局链: ${GREEN}✔ 正常挂载 (已接管 IPv4+IPv6 全流量)${RESET}"
    else
        echo -e "   策略路由双栈全局链: ${RED}✘ 未挂载${RESET}"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_global_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未激活${RESET}"
        if [ -f "$SERVICE_FILE" ] && grep -q "tun2socks" "$SERVICE_FILE"; then proxy_status="${YELLOW}全面激活中${RESET}"; fi
        echo -e "${CYAN}11. 真实全局出站管理 (新tun2socks双栈方案)${RESET}\n状态: $proxy_status\n1. 一键开启全局透明出站\n2. 关闭全局透明出站\n3. 验证链路状态\n0. 返回"
        read -r -p "选择: " sub_choice
        case "$sub_choice" in
            1) start_global_tun_proxy ;;
            2) stop_global_tun_proxy ;;
            3) verify_global_tun_proxy ;;
            *) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ── 5. 面板常规功能模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then panel_status="${GREEN}运行中${RESET}"; else panel_status="${RED}未运行${RESET}"; fi
    if [ -f "$SERVICE_FILE" ] && grep -q "tun2socks" "$SERVICE_FILE"; then panel_status="${panel_status} ${GREEN}| 真·全局开启${RESET}"
    elif systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then panel_status="${panel_status} ${GREEN}| 谷歌分流开启${RESET}"
    else panel_status="${panel_status} ${YELLOW}| 常规代理模式${RESET}"; fi
    if [ -f "$INSTALL_BIN" ]; then panel_version=$("$INSTALL_BIN" --version 2>/dev/null | awk '{print $2}'); else panel_version="${RED}未安装${RESET}"; fi
}

menu_install() {
    write_config "127.0.0.1" "1080" "" ""
    download_and_extract
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    install -m 0750 -o root -g root -d "$DATA_DIR"
    write_systemd "false"
    systemctl start "$SERVICE_NAME"
    ok "CF-WARP-Rust 安全部署成功！"
}

# ── 6. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}   CF-WARP-RUST IPv6 终极面板   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version:-0.3.2}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 WARP-Rust${RESET}"
    echo -e "${GREEN} 2. 更新 WARP-Rust${RESET}"
    echo -e "${GREEN} 3. 卸载全套组件${RESET}"
    echo -e "${GREEN} 4. 启动 / 5. 停止 / 6. 重启${RESET}"
    echo -e "${YELLOW}10. 谷歌WARP分流管理 (原iptables方案)${RESET}"
    echo -e "${CYAN}11. 真实全局出站管理 (新tun2socks双栈方案)${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    read -r -p "请输入选项: " choice
    case "$choice" in
        1) menu_install ;;
        2) download_and_extract && systemctl stop "$SERVICE_NAME" && install -m 0755 "$TARGET_BIN_PATH" "$INSTALL_BIN" && systemctl start "$SERVICE_NAME" ;;
        3) systemctl stop "$PROXY_SERVICE_NAME" "$SERVICE_NAME" 2>/dev/null; rm -f "$INSTALL_BIN" "$SERVICE_FILE" "$TUN2SOCKS_BIN"; systemctl daemon-reload; ok "完全卸载" ;;
        4) systemctl start "$SERVICE_NAME" ;;
        5) systemctl stop "$SERVICE_NAME" ;;
        6) systemctl restart "$SERVICE_NAME" ;;
        10) menu_transparent_proxy_center ;;
        11) menu_global_proxy_center ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键返回主面板..."
done
