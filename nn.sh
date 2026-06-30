#!/usr/bin/env bash

# ==============================================================================
#  cf-warp-rust 一键管理面板（支持 GitHub 代理轮询版）
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="Shannon-x/cf-warp-rust"
export SERVICE_NAME="warp-rust"
export SERVICE_USER="warp"
export INSTALL_BIN="/usr/local/bin/warp-rust"
export CONF_DIR="/etc/warp-rust"
export CONF_FILE="${CONF_DIR}/config.toml"
export DATA_DIR="/var/lib/warp-rust"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 透明代理相关变量
export REDSOCKS_CONF="/etc/redsocks.conf"
export PROXY_SERVICE_NAME="warp-google-proxy"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"
export PROXY_RULES_SCRIPT="${DATA_DIR}/warp-google-iptables.sh"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# GitHub 镜像代理池（支持自动轮询重试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

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

# ── 基础环境校验 ──────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# 动态识别操作系统包管理器
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os

# 仅检查主程序运行和下载解压所需的基础工具
REQUIRED_CMDS="curl tar sed grep awk"
MISSING_CMDS=""

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失下载/解压必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y $MISSING_CMDS >/dev/null 2>&1
            else
                yum install -y $MISSING_CMDS >/dev/null 2>&1
            fi
            ;;
        *)
            die "未知的操作系统，请手动安装基础组件: $MISSING_CMDS"
            ;;
    esac

    for cmd in $MISSING_CMDS; do
        if ! command -v "$cmd" &> /dev/null; then
            die "自动安装组件 [ $cmd ] 失败，请检查网络或系统源。"
        fi
    done
    ok "主程序基础依赖补全成功！"
fi

# ── 1. 核心下载与组件解压 ───────────────────────────────────────────────────
detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH (本面板目前仅支持 x86_64 及 aarch64)" ;;
    esac
}

fetch_latest_version() {
    info "正在查询 GitHub 获取最新 Release 版本号..."
    
    # 设定一个已知的最新稳定版作为兜底（当前为 v0.3.3）
    local DEFAULT_VER="v0.3.3"
    TMP_API="$(mktemp)"
    
    # 1. 尝试直接官方 API 请求
    if curl -sSL -H "Accept: application/vnd.github+json" --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" > "$TMP_API"; then
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_API" | head -n 1)"
        if [ -n "$VERSION" ]; then 
            rm -f "$TMP_API"
            export VERSION
            return 0
        fi
    fi
    rm -f "$TMP_API"
    
    # 2. 如果 API 失败，通过代理池解析
    warn "直连 GitHub API 获取版本失败，尝试通过代理源池检索..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_desc="${proxy:-官方直连}"
        # 允许 curl 跟随重定向 (-L)，并兼容镜像源可能改变的 URL 结构
        VERSION=$(curl -sS -L --max-time 6 "${proxy}https://github.com/${REPO}/releases/latest" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        
        if [ -n "$VERSION" ]; then
            ok "成功通过代理 [ ${proxy_desc} ] 锁定最新版本号: ${GREEN}${VERSION}${RESET}"
            export VERSION
            return 0
        fi
    done

    # 3. 终极防卡死：如果由于镜像格式问题拿不到，直接使用已知最新的 v0.3.3 强行推进
    warn "未能从网页动态解析到版本号，正在为你使用已知最新版本进行部署..."
    export VERSION="$DEFAULT_VER"
    ok "已锁定首选版本号: ${GREEN}${VERSION}${RESET}"
}
download_and_extract() {
    detect_target
    fetch_latest_version
    info "正在匹配系统环境形态: ${YELLOW}${TARGET}${RESET}"

    ASSET="warp-rust-${VERSION}-${TARGET}.tar.gz"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    local dl_success=false

    # 开始循环轮询代理池进行资产包下载
    for proxy in "${GITHUB_PROXY[@]}"; do
        local proxy_desc="${proxy:-官方直连}"
        local dl_url="${proxy}https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
        
        info "正在通过 [ ${proxy_desc} ] 下载资产包..."
        if curl -fsSL --connect-timeout 10 --max-time 120 -o "$TMP/$ASSET" "$dl_url"; then
            # 尝试下载对应的 sha256 签名（可选校验）
            if curl -fsSL --connect-timeout 5 --max-time 15 -o "$TMP/$ASSET.sha256" "${dl_url}.sha256" &> /dev/null; then
                if command -v sha256sum &> /dev/null; then
                    LOCAL_SHA=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
                    REMOTE_SHA=$(awk '{print $1}' "$TMP/$ASSET.sha256")
                    if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
                        ok "数字签名校验通过。"
                    else
                        warn "数字签名不匹配，该镜像源文件可能损坏，尝试下一个..."
                        continue
                    fi
                fi
            fi
            dl_success=true
            break
        else
            warn "通过 [ ${proxy_desc} ] 下载失败，准备切换下一个节点..."
        fi
    done

    if [ "$dl_success" = false ]; then
        die "所有 GitHub 代理节点均下载失败！请检查 VPS 网络或稍后再试。"
    fi

    tar xzf "$TMP/$ASSET" -C "$TMP"
    EXTRACTED_BIN=$(find "$TMP" -type f -name "warp-rust" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "解压成功，但在归档包内未找到 warp-rust 主程序！"
    export TARGET_BIN_PATH="$EXTRACTED_BIN"
}

# ── 2. 配置文件生成器 ─────────────────────────────────────────────────────────
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
reconnect_after        = 1
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
servers = ["1.1.1.1:53", "1.0.0.1:53"]
timeout = "3s"
cache_ttl = "60s"
EOF
}

write_systemd() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=cf-warp-rust Cloudflare WARP Proxy Client
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# ── 3. 透明代理二级专属菜单控制中心 ───────────────────
start_transparent_proxy() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明分流代理已经处于启动运行状态，无需重复启动。"
        return
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "核心 WARP-Rust 未在后台运行！透明代理依赖底层代理通道，请先开启主服务。"
        return
    fi

    local current_bind
    current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local warp_ip="${current_bind%%:*}" local warp_port="${current_bind##*:}"
    [ -z "$warp_port" ] && warp_port="1080"
    [ -z "$warp_ip" ] && warp_ip="127.0.0.1"

    local has_auth
    has_auth=$(grep -i 'username' "$CONF_FILE" | head -n 1)
    if [ -n "$has_auth" ] && [ "$warp_ip" != "127.0.0.1" ] && [ "$warp_ip" != "localhost" ]; then
        warn "当前 WARP 节点开启了账号密码鉴权。透明分流暂不支持有密公网代理。"
        warn "建议在主菜单 [4.修改配置] 中将监听 IP 切换回 127.0.0.1 并不设置密码后再试。"
        return
    fi

    info "正在检查并安装透明代理核心组件 (redsocks / iptables)..."
    local proxy_missing=""
    if ! command -v redsocks &>/dev/null; then proxy_missing="$proxy_missing redsocks"; fi
    if ! command -v iptables &>/dev/null; then proxy_missing="$proxy_missing iptables"; fi

    if [ -n "$proxy_missing" ]; then
        info "正在为系统补齐透明分流组件群:${YELLOW}$proxy_missing${RESET}..."
        case $OS in
            ubuntu|debian)
                apt-get update -qy && apt-get install -y $proxy_missing >/dev/null 2>&1
                ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then
                    dnf install -y $proxy_missing >/dev/null 2>&1
                else
                    yum install -y $proxy_missing >/dev/null 2>&1
                fi
                ;;
        esac
    fi

    if ! command -v redsocks &>/dev/null || ! command -v iptables &>/dev/null; then
        die "透明代理所需核心网络组件安装失败，请检查你的系统源网络环境。"
    fi

    if systemctl is-enabled redsocks >/dev/null 2>&1 || systemctl is-active redsocks >/dev/null 2>&1; then
        info "检测到系统自带的默认 redsocks 服务，正在将其解绑卸载以防端口冲突..."
        systemctl stop redsocks >/dev/null 2>&1
        systemctl disable redsocks >/dev/null 2>&1
    fi

    info "阻断并优化系统的 Google IPv6 路由解析..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    cat <<EOF > "$REDSOCKS_CONF"
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = ${warp_port};
    type = socks5;
}
EOF

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
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
Description=Cloudflare WARP Google Transparent Proxy (Redsocks Engine)
After=network.target ${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c ${REDSOCKS_CONF}
ExecStartPost=${PROXY_RULES_SCRIPT} start
ExecStop=${PROXY_RULES_SCRIPT} stop
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    
    info "正在拉起透明代理引擎..."
    systemctl start "$PROXY_SERVICE_NAME"
    
    sleep 1.5
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        ok "Google 透明分流代理已彻底成功启动并挂载！"
    else
        warn "透明代理拉起异常，正在为你输出实时崩溃错误日志："
        journalctl -u "$PROXY_SERVICE_NAME" -n 15 --no-pager
    fi
}

stop_transparent_proxy() {
    if ! systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明代理本来就处于关闭状态。"
        return
    fi
    systemctl stop "$PROXY_SERVICE_NAME"
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    ok "Google 透明代理已被安全停止，系统 NetFilter 劫持链已完全卸载。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 透明代理链路深度验证 =========${RESET}"
    
    info "1. 正在检索系统 iptables 劫持规则 status..."
    if command -v iptables &>/dev/null && iptables -t nat -L OUTPUT -n | grep -q "WARP_GOOGLE"; then
        echo -e "   iptables 拦截链: ${GREEN}✔ 正常挂载 (已接管系统 OUTPUT 流量)${RESET}"
    else
        echo -e "   iptables 拦截链: ${RED}✘ 未挂载 (Google 流量目前处于直连状态)${RESET}"
    fi

    info "2. 正在通过链路层测试 Google 真实连通性 (直接请求)..."
    local http_status
    http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://www.google.com")

    if [ "$http_status" -eq 200 ] || [ "$http_status" -eq 301 ] || [ "$http_status" -eq 302 ]; then
        echo -e "   联通性测试结果: ${GREEN}✔ 成功连接 (HTTP 状态码: ${http_status})${RESET}"
        
        local total_time
        total_time=$(curl -o /dev/null -s -w "%{time_total}" --max-time 5 "https://www.google.com")
        echo -e "   透明代理端延迟: ${YELLOW}${total_time} 秒${RESET}"
    else
        echo -e "   联通性测试结果: ${RED}✘ 失败 (无法连接 Google，状态码: ${http_status:-超时/断流})${RESET}"
        warn "提示: 请检查主核心 WARP 账户是否有效，或主服务是否真的获取到了 Cloudflare 的网络分配。"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
            proxy_status="${YELLOW}运行中 (已自动接管 Google IP 流量)${RESET}"
        fi

        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}      Google 透明代理管理控制菜单       ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}1. 开启透明代理${RESET}"
        echo -e "${GREEN}2. 关闭透明代理${RESET}"
        echo -e "${GREEN}3. 查看并验证代理连通性${RESET}"
        echo -e "${0}. 返回主菜单${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        
        read -r -p "$(echo -e "${GREEN}请输入子选项: ${RESET}")" sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) stop_transparent_proxy ;;
            3) verify_transparent_proxy ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键继续...${RESET}")"
    done
}

# ── 4. 面板常规功能模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        panel_status="${panel_status} ${GREEN}| 透明分流:已开启${RESET}"
    else
        panel_status="${panel_status} ${GREEN}| 透明分流:未开启${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        local raw_ver
        raw_ver=$("$INSTALL_BIN" --version 2>/dev/null | awk '{print $2}')
        panel_version="${raw_ver:-已安装}"
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "$CONF_FILE" ]; then
        panel_port=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ' )
    else
        panel_port="127.0.0.1:1080"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在运行中的实例文件。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [默认: 127.0.0.1]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-127.0.0.1}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}")" input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=1080
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 检测到公网绑定，必须强制设置鉴权！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名: ${RESET}")" opt_user
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 (≥16位): ${RESET}")" opt_pass
            if [ ${#opt_pass} -ge 16 ]; then break; fi
        done
    else
        read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (本地回环默认留空免密): ${RESET}")" opt_user
        if [ -n "$opt_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass
        fi
    fi

    download_and_extract

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
          || adduser --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    install -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" -d "$DATA_DIR"
    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    write_systemd

    info "正在拉起后台服务..."
    systemctl start "$SERVICE_NAME"
    
    local is_ok=1
    for i in {1..5}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then is_ok=0; break; fi
        sleep 1
    done

    if [ "$is_ok" -eq 0 ]; then
        ok "CF-WARP-Rust 安全部署成功！"
    else
        warn "部署完成，但初始化较慢，请稍后选择 [8] 查看日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "未检测到系统服务，请先选择 [1] 进行安装。"
    download_and_extract
    systemctl stop "$SERVICE_NAME"
    install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$INSTALL_BIN"
    systemctl start "$SERVICE_NAME"
    ok "组件已成功平滑更新。"
}

menu_uninstall() {
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    rm -f "$PROXY_SERVICE_FILE" "$REDSOCKS_CONF" "$PROXY_RULES_SCRIPT"

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONF_DIR" "$DATA_DIR"
    userdel "$SERVICE_USER" >/dev/null 2>&1
    ok "主程序与透明代理规则已全部清理卸载完毕。"
}

menu_edit_config() {
    [ -f "$CONF_FILE" ] || die "未发现任何配置文件，请先执行安装步骤。"
    local current_bind
    current_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local current_ip="${current_bind%%:*}" local current_port="${current_bind##*:}"
    local current_user
    current_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local current_pass
    current_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')

    [ -z "$current_ip" ] && current_ip="127.0.0.1"
    [ -z "$current_port" ] && current_port="1080"

    echo -e "\n${GREEN}==== [修改内核参数配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$current_ip}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port="$current_port"
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 公网暴露下必须强制设定鉴权密码！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}]: ${RESET}")" input_user
            opt_user="${input_user:-$current_user}"
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 [直接回车保持原样]: ${RESET}")" input_pass
            opt_pass="${input_pass:-$current_pass}"
            if [ ${#opt_pass} -ge 16 ]; then break; fi
        done
    else
        if [ -n "$current_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}，回车不变，输入 ${RED}none${GREEN} 清除鉴权]: ${RESET}")" input_user
            if [ -z "$input_user" ]; then
                opt_user="$current_user" opt_pass="$current_pass"
            elif [ "$input_user" = "none" ]; then
                opt_user="" opt_pass=""
            else
                opt_user="$input_user"
                read -r -p "$(echo -e "${GREEN}请输入新密码: ${RESET}")" opt_pass
            fi
        else
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (留空默认不启用): ${RESET}")" opt_user
            if [ -n "$opt_user" ]; then read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass; fi
        fi
    fi

    write_config "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
            systemctl restart "$PROXY_SERVICE_NAME"
        fi
        ok "配置已覆盖，全套服务已同步重启生效！"
    else
        ok "配置已成功重写更新。"
    fi
}

menu_show_node_config() {
    if [ ! -f "$CONF_FILE" ]; then die "未检测到有效的服务配置文件。"; fi
    echo -e "\n${GREEN}========= 当前节点本地配置 =========${RESET}"
    grep -A 5 "\[server\]" "$CONF_FILE"
    echo -e "${GREEN}====================================${RESET}"

    local full_bind
    full_bind=$(grep -i 'bind' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local bind_ip="${full_bind%%:*}" local bind_port="${full_bind##*:}"
    local connect_ip="$bind_ip"
    if [ "$connect_ip" = "0.0.0.0" ]; then connect_ip="127.0.0.1"; fi

    local auth_user
    auth_user=$(grep -i 'username' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')
    local auth_pass
    auth_pass=$(grep -i 'password' "$CONF_FILE" | head -n 1 | awk -F '=' '{print $2}' | tr -d '" ')

    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"
    fi

    echo -e "\n${YELLOW}[正在通过本地代理验证流量连通性...]${RESET}"
    TMP_TRACE="$(mktemp)"
    if curl -sS --max-time 6 $proxy_args "https://1.1.1.1/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip
        trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_warp
        trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_colo
        trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')

        echo -e "\n${GREEN}========= Cloudflare 真实性报告 =========${RESET}"
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ${GREEN}✔ 通过 (流量确实从 Cloudflare 网络流出)${RESET}"
            echo -e " WARP 激活状态:  ${GREEN}${trace_warp}${RESET}"
        else
            echo -e " 隧道验证状态 :  ${RED}✘ 未通过 (可能没有走代理隧道)${RESET}"
            echo -e " WARP 激活状态:  ${RED}${trace_warp:-off}${RESET}"
        fi
        echo -e " CF 分配出口IP:  ${YELLOW}${trace_ip}${RESET}"
        echo -e " CF 边缘数据中心: ${YELLOW}${trace_colo}${RESET}"
        echo -e "${GREEN}=========================================${RESET}"
    else
        echo -e "${RED}[验证失败]${RESET} 无法通过代理连接至验证端点。"
    fi
    rm -f "$TMP_TRACE"
}

# ── 5. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         CF-WARP 面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 WARP-Rust${RESET}"
    echo -e "${GREEN} 2. 更新 WARP-Rust${RESET}"
    echo -e "${GREEN} 3. 卸载全套组件${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 WARP-Rust${RESET}"
    echo -e "${GREEN} 6. 停止 WARP-Rust${RESET}"
    echo -e "${GREEN} 7. 重启 WARP-Rust${RESET}"
    echo -e "${GREEN} 8. 查看内核日志${RESET}"
    echo -e "${GREEN} 9. 查看配置与出口状态${RESET}"
    echo -e "${YELLOW}10. 谷歌WARP分流${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "动作: 核心启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "动作: 核心停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "动作: 核心重启成功" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
        9) menu_show_node_config ;;
        10) menu_transparent_proxy_center ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
