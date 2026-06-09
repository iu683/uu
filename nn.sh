#!/usr/bin/env bash
set -e

# ==============================================================================
#   Usque (MASQUE-WARP) Alpine 专属全能控制面板 (含 Google 透明代理 与 Tun2Socks)
# ==============================================================================

# --- 核心主程序变量 ---
export REPO_USQUE="Diniboy1123/usque"
export SERVICE_NAME="usque"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 模块一：Redsocks 透明代理专属变量 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"

# --- 模块二：Hev-Socks5-Tunnel 专属变量 ---
export HEV_REPO="heiher/hev-socks5-tunnel"
export HEV_SERVICE_NAME="tun2socks"
export HEV_CONFIG_DIR="/etc/tun2socks"
export HEV_CONFIG_FILE="${HEV_CONFIG_DIR}/config.yaml"
export HEV_BIN="/usr/local/bin/tun2socks"

# 配色方案
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 备用 DNS64 服务器
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/' '')

[[ "$EUID" -ne 0 ]] && echo -e "${RED}[错误]${RESET} 请使用 root 权限运行！" && exit 1

# 强制 Alpine 环境底层修复与内核转发初始化
[ ! -d "$DATA_DIR" ] && mkdir -p "$DATA_DIR"
[ ! -f /sbin/iptables ] && [ -f /usr/sbin/iptables ] && ln -sf /usr/sbin/iptables /sbin/iptables || true
[ ! -f /sbin/ip ] && [ -f /usr/sbin/ip ] && ln -sf /usr/sbin/ip /sbin/ip || true

if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi
modprobe iptable_nat 2>/dev/null || true
modprobe ip_tables 2>/dev/null || true
modprobe xt_REDIRECT 2>/dev/null || true

info() { echo -e "${BLUE}[信息]${RESET} $1"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $1"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $1"; }
die()  { echo -e "${RED}[错误]${RESET} $1" >&2; exit 1; }
error() { echo -e "${RED}[错误]${RESET} $1"; }

# --- 基础依赖环境预检 ---
check_deps() {
    local missing_deps=""
    if ! command -v unzip >/dev/null 2>&1; then missing_deps="$missing_deps unzip"; fi
    if ! command -v ip >/dev/null 2>&1; then missing_deps="$missing_deps iproute2"; fi
    if ! command -v curl >/dev/null 2>&1; then missing_deps="$missing_deps curl"; fi

    if [ -n "$missing_deps" ]; then
        warn "未检测到必要组件，正在尝试自动通过 apk 补齐: $missing_deps..."
        apk add --no-cache unzip iproute2 curl >/dev/null 2>&1 || true
    fi
}

# --- DNS64/网络加速专属工具函数群 ---
test_dns64_server() {
    local dns_server=$1
    if ping6 -c 3 -W 2 "$dns_server" &>/dev/null; then return 0; else return 1; fi
}

test_github_access() {
    if curl -s -I -m 10 https://github.com >/dev/null; then return 0; else return 1; fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
    fi
}

set_dns64_servers() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    
    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    if test_github_access; then return 0; fi
    
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then return 0; fi
        fi
    done
    
    restore_dns_config "$resolv_conf" "$resolv_conf_bak"
    return 1
}

cleanup_ip_rules() {
    /sbin/ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route del default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule del lookup 20 pref 20 2>/dev/null || true
    /sbin/ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true

    while /sbin/ip rule del pref 15 2>/dev/null; do true; done
    while /sbin/ip -6 rule del pref 15 2>/dev/null; do true; done
    while /sbin/ip rule del pref 5 2>/dev/null; do true; done
    while /sbin/ip -6 rule del pref 5 2>/dev/null; do true; done
}

# --- 1. 下载 Usque 核心模块 ---
download_bin() {
    check_deps
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac

    info "正在检索 Usque 最新版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO_USQUE}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done

    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    local success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        if curl -fsSL -L -o "$tmp_dir/zip" "${proxy}https://github.com/${REPO_USQUE}/releases/download/${latest_tag}/${zip_name}"; then
            success=1; break
        fi
    done

    [ "$success" -ne 1 ] && { rm -rf "$tmp_dir"; die "下载失败。"; }
    unzip -q -o "$tmp_dir/zip" -d "$tmp_dir"
    cp -f "$tmp_dir/usque" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    rm -rf "$tmp_dir"
}

# --- 2. 本地注册 ---
register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then
        has_v4=1
    fi

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    if "${INSTALL_BIN}" register; then
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            if [ -z "$v6_ep" ]; then
                v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            fi
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
        fi
    else
        die "注册失败。提示：请确保你的 VPS 已开启 IPv6 外部访问能力。"
    fi
}

# --- 3. 写入 Alpine OpenRC 服务 ---
write_systemd() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u \"${user}\" -w \"${pass}\""

    cat <<EOF > "/etc/init.d/${SERVICE_NAME}"
#!/sbin/openrc-run
supervisor="supervise-daemon"
name="Usque WARP Service"
command="${INSTALL_BIN}"
command_args="--config ${CONF_FILE} ${args}"
directory="${CONF_DIR}"
respawn_delay=3
respawn_max=0
EOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

# --- 4. 状态获取 ---
get_status_info() {
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 && panel_status="${YELLOW}运行中${RESET}" || panel_status="${RED}未运行${RESET}"

    if [ -f "$INSTALL_BIN" ]; then
        local ver=$("$INSTALL_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        panel_version="${YELLOW}v${ver:-已安装}${RESET}"
    else
        panel_version="${RED}未安装${RESET}"
    fi
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r m_mode m_ip m_port m_user m_pass < "$META_FILE"
        panel_port="${m_mode}://$m_ip:$m_port"
    else
        panel_port="${RED}未配置${RESET}"
    fi
}

# --- 5. 修改配置 ---
menu_edit_config() {
    [ -f "$META_FILE" ] || die "未发现任何配置记录。"
    
    local o_mode o_ip o_port o_user o_pass
    local m_choice n_mode n_ip n_port i_user n_user i_pass n_pass
    
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"

    echo -e "==== [修改监听配置] ===="
    echo -e "${YELLOW}说明：直接回车保持不变，输入 read 则清空该项${RESET}"
    
    echo "1. SOCKS5 模式"
    echo "2. HTTP 模式"
    read -r -p "选择模式 [当前: $o_mode]: " m_choice
    case "$m_choice" in
        1) n_mode="SOCKS5" ;;
        2) n_mode="HTTP" ;;
        *) n_mode="$o_mode" ;;
    esac

    read -r -p "监听 IP [当前: $o_ip]: " n_ip
    n_ip="${n_ip:-$o_ip}"

    read -r -p "监听端口 [当前: $o_port]: " n_port
    n_port="${n_port:-$o_port}"
    
    read -r -p "用户名 [当前: ${o_user:-空}]: " i_user
    if [ -z "$i_user" ]; then
        n_user="$o_user"
    elif [ "$i_user" = "read" ]; then
        n_user=""
    else
        n_user="$i_user"
    fi

    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then
        n_pass="$o_pass"
    elif [ "$i_pass" = "read" ]; then
        n_pass=""
    else
        n_pass="$i_pass"
    fi

    write_systemd "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" restart && ok "配置已更新并重启 Alpine 服务。"
    sleep 0.5
}

# --- 6. 验证逻辑 ---
menu_show_node_config() {
    [ -f "$META_FILE" ] || die "记录不存在。"
    local b_mode b_ip b_port b_user b_pass
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"

    echo -e "\n========= 当前服务详情 ========="
    echo " 代理模式 : ${b_mode}"
    echo " 监听地址 : ${b_ip}:${b_port}"
    [[ -n "$b_user" ]] && echo " 鉴权信息 : ${b_user}:${b_pass}" || echo " 鉴权状态 : 未开启"
    echo "================================"

    local p_url="socks5://"
    [[ "$b_mode" == "HTTP" ]] && p_url="http://"
    [[ -n "$b_user" ]] && p_url="${p_url}${b_user}:${b_pass}@"
    
    local test_ip="$b_ip"
    [[ "$test_ip" == "0.0.0.0" ]] && test_ip="127.0.0.1"
    [[ "$test_ip" == "::" ]] && test_ip="[::1]"
    p_url="${p_url}${test_ip}:${b_port}"

    info "正在验证出口状态..."
    if curl -sS --max-time 10 -x "$p_url" "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp=on"; then
        ok "验证成功！WARP 已开启。"
    else
        warn "验证失败，请检查端口、鉴权或端口是否被阻断。"
    fi
}

# ==============================================================================
#   模块一：Google 透明代理 (Alpine OpenRC + iptables + redsocks)
# ==============================================================================
start_transparent_proxy() {
    local is_active=0
    rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1 && is_active=1
    if [ "$is_active" -eq 1 ]; then return; fi

    local core_active=0
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 && core_active=1
    if [ "$core_active" -ne 1 ]; then return; fi

    local warp_ip="127.0.0.1" warp_port="1080" has_auth=""
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r _ warp_ip warp_port has_auth _ < "$META_FILE"
    fi

    if [ -n "$has_auth" ] && [ "$warp_ip" != "127.0.0.1" ] && [ "$warp_ip" != "localhost" ]; then
        return
    fi

    if ! command -v redsocks &>/dev/null; then
        apk add --no-cache redsocks iptables >/dev/null 2>&1 || true
    fi

    rc-service redsocks stop >/dev/null 2>&1 || true
    rc-update del redsocks default >/dev/null 2>&1 || true

    /sbin/ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

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

    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/sh
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
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE
    /sbin/iptables -t nat -A WARP_GOOGLE -d 127.0.0.0/8 -j RETURN
    for ip in $GOOGLE_IPS; do
        /sbin/iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    /sbin/iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || /sbin/iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    cat <<EOF > "/etc/init.d/${PROXY_SERVICE_NAME}"
#!/sbin/openrc-run
supervisor="supervise-daemon"
name="Cloudflare WARP Google Transparent Proxy"
command="/usr/sbin/redsocks"
command_args="-c ${REDSOCKS_CONF}"
respawn_delay=2

start_post() {
    ${PROXY_RULES_SCRIPT} start
}

stop_post() {
    ${PROXY_RULES_SCRIPT} stop
}
EOF
    chmod +x "/etc/init.d/${PROXY_SERVICE_NAME}"
    rc-update add "$PROXY_SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$PROXY_SERVICE_NAME" zap && rc-service "$PROXY_SERVICE_NAME" start
}

stop_transparent_proxy() {
    rc-service "$PROXY_SERVICE_NAME" stop 2>/dev/null || true
    rc-service "$PROXY_SERVICE_NAME" zap 2>/dev/null || true
}

test_google_connectivity() {
    info "正在验证谷歌透明代理连通性..."
    local g_status=$(curl -I -s --max-time 6 https://www.google.com | head -n 1)
    if [[ "$g_status" == *"200"* || "$g_status" == *"302"* ]]; then
        ok "连通性验证成功！Google 请求已被透明拦截并分流处理。"
    else
        warn "未检测到谷歌响应。请确保底层核心模块已运行并且路由拦截正常。"
    fi
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1 && proxy_status="${YELLOW}运行中${RESET}"
        
        # 完美匹配你的 37 字符 Google 透明代理管理控制菜单模板
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}      Google 透明代理管理控制菜单       ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}1. 开启 Google分流${RESET}"
        echo -e "${GREEN}2. 关闭 Google分流${RESET}"
        echo -e "${GREEN}3. 查看并验证代理连通性${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        
        read -r -p "请输入子选项: " sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy && ok "分流引擎已在 Alpine 启动。" ;;
            2) stop_transparent_proxy && ok "分流引擎已停止并清空拦截路由。" ;;
            3) test_google_connectivity ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}


# ==============================================================================
#   模块二：Hev-Socks5-Tunnel 全局虚拟网卡三层控制中心 (Tun2Socks Alpine 专版)
# ==============================================================================
write_hev_config() {
    mkdir -p "$HEV_CONFIG_DIR"
    local current_addr="" current_port="" current_user="" current_pass=""
    if [ -f "$HEV_CONFIG_FILE" ]; then
        current_addr=$(grep -E '^[[:space:]]*address:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_port=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_user=$(grep -E '^[[:space:]]*username:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_pass=$(grep -E '^[[:space:]]*password:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    fi

    if [ -z "$current_addr" ] && [ -f "$META_FILE" ]; then
        IFS='|' read -r _ m_ip m_port m_user m_pass < "$META_FILE"
        current_addr=$m_ip; current_port=$m_port; current_user=$m_user; current_pass=$m_pass
    fi

    local input_addr
    while true; do
        read -r -p "请输入Socks5服务器地址 [$current_addr]: " input_addr
        input_addr="${input_addr:-$current_addr}"
        if [ -n "$input_addr" ]; then break; else error "地址不能为空。"; fi
    done

    local input_port
    while true; do
        read -r -p "请输入Socks5服务器端口 [$current_port]: " input_port
        input_port="${input_port:-$current_port}"
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then break; else error "请输入 1-65535 的合规端口。"; fi
    done

    read -r -p "请输入用户名 (保持/留空回车，清空输入 none) [${current_user:-无}]: " input_user
    input_user="${input_user:-$current_user}"
    [ "$input_user" = "none" ] && input_user=""

    local input_pass=""
    if [ -n "$input_user" ]; then
        read -r -p "请输入密码 (保持/留空回车，清空输入 none) [${current_pass:-无}]: " input_pass
        input_pass="${input_pass:-$current_pass}"
        [ "$input_pass" = "none" ] && input_pass=""
    fi

    input_addr=$(echo "$input_addr" | tr -d '\r' | sed "s/'/''/g")
    input_user=$(echo "$input_user" | tr -d '\r' | sed "s/'/''/g")
    input_pass=$(echo "$input_pass" | tr -d '\r' | sed "s/'/''/g")

    cat > "$HEV_CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 1500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $input_port
  address: '$input_addr'
  udp: 'udp'
$( [ -n "$input_user" ] && echo "  username: '$input_user'" )
$( [ -n "$input_pass" ] && echo "  password: '$input_pass'" )
  mark: 438
EOF
}

install_hev_tunnel() {
    cleanup_ip_rules
    rc-service "$HEV_SERVICE_NAME" stop >/dev/null 2>&1 || true

    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    if ! set_dns64_servers "$RESOLV_CONF" "$RESOLV_CONF_BAK"; then return 1; fi

    local latest_version=""
    local DOWNLOAD_URL=""
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            DOWNLOAD_URL="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            break
        fi
    done

    # 恢复 Alpine DNS
    cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    if [ -z "$latest_version" ] || [ -z "$DOWNLOAD_URL" ]; then
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK"
        return 1
    fi

    cleanup_on_fail() { trap - INT TERM EXIT; restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK"; return 1; }
    trap cleanup_on_fail INT TERM EXIT
    
    local dl_success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        if curl -L -f -o "$HEV_BIN" "${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"; then
            dl_success=1; break
        fi
    done
    trap - INT TERM EXIT

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK"
    if [ "$dl_success" -ne 1 ]; then return 1; fi
    chmod +x "$HEV_BIN"

    write_hev_config
    setup_hev_routes
}

setup_hev_routes() {
    local WARP_PORT=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    [ -z "$WARP_PORT" ] && WARP_PORT="1080"

    local MAIN_IP=$(/sbin/ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local MAIN_IP6=$(/sbin/ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

    cat <<EOF > /var/lib/usque/tun2socks_routes.sh
#!/bin/sh
/sbin/iptables -t nat -I OUTPUT -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
/sbin/ip -6 rule add to ::/0 dport 22 lookup main pref 5 2>/dev/null || true
/sbin/ip -6 rule add to ::/0 sport 22 lookup main pref 5 2>/dev/null || true
/sbin/ip rule add to 127.0.0.1 lookup main pref 4 2>/dev/null || true
/sbin/ip -6 rule add to ::1 lookup main pref 4 2>/dev/null || true
/sbin/ip rule add to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4 2>/dev/null || true
/sbin/ip rule add fwmark 438 lookup main pref 10 2>/dev/null || true
/sbin/ip -6 rule add fwmark 438 lookup main pref 10 2>/dev/null || true
/sbin/ip route add default dev tun0 table 20 2>/dev/null || true
/sbin/ip rule add lookup 20 pref 20 2>/dev/null || true
[ -n "$MAIN_IP" ] && /sbin/ip rule add from $MAIN_IP lookup main pref 15 2>/dev/null || true
[ -n "$MAIN_IP6" ] && /sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15 2>/dev/null || true
/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
EOF
    chmod +x /var/lib/usque/tun2socks_routes.sh

    cat <<EOF > "/etc/init.d/${HEV_SERVICE_NAME}"
#!/sbin/openrc-run
supervisor="supervise-daemon"
name="Tun2Socks Global Device"
command="${HEV_BIN}"
command_args="${HEV_CONFIG_FILE}"
respawn_delay=2

start_post() {
    /bin/sleep 1
    /var/lib/usque/tun2socks_routes.sh
}

stop_post() {
    /sbin/ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route del default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule del lookup 20 pref 20 2>/dev/null || true
}
EOF
    chmod +x "/etc/init.d/${HEV_SERVICE_NAME}"
    rc-update add "$HEV_SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$HEV_SERVICE_NAME" zap && rc-service "$HEV_SERVICE_NAME" start
}

uninstall_hev_tunnel() {
    cleanup_ip_rules
    rc-service "$HEV_SERVICE_NAME" stop 2>/dev/null || true
    rc-service "$HEV_SERVICE_NAME" zap 2>/dev/null || true
    rm -f "/etc/init.d/${HEV_SERVICE_NAME}" /var/lib/usque/tun2socks_routes.sh 2>/dev/null || true
    [ -d "$HEV_CONFIG_DIR" ] && rm -rf "$HEV_CONFIG_DIR"
    [ -f "$HEV_BIN" ] && rm -f "$HEV_BIN"
}

test_hev_exit_ip() {
    local ip_info=""
    local test_urls=("https://api.ipify.org?format=json" "https://ipinfo.io/json" "https://ifconfig.me/all.json")

    for url in "${test_urls[@]}"; do
        ip_info=$(curl --noproxy "*" -s -m 8 "$url" 2>/dev/null || echo "")
        [ -n "$ip_info" ] && break
    done

    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        if echo "$ip_info" | grep -q "{"; then
            echo "$ip_info" | sed 's/["{}]//g' | sed 's/,/\n/g' | sed 's/^ *//'
        else
            echo -e "落地真实出口 IP: ${YELLOW}$ip_info${RESET}"
        fi
        echo -e "${GREEN}----------------------------------------${RESET}"
    fi
}

menu_hev_tunnel_center() {
    while true; do
        clear
        local status_show="${RED}未运行${RESET}"
        rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1 && status_show="${YELLOW}运行中${RESET}"
        
        local version_show="${RED}未安装${RESET}"
        if [ -f "$HEV_BIN" ]; then
            local ver_raw=$("$HEV_BIN" --version 2>&1 | grep "Version:" | awk '{print $2}')
            version_show="${YELLOW}${ver_raw:-已安装}${RESET}"
        fi

        local port_show="${RED}无配置${RESET}"
        if [ -f "$HEV_CONFIG_FILE" ]; then
            local port=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
            local addr=$(grep -E '^[[:space:]]*address:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
            port_show="${YELLOW}${addr}:${port}${RESET}"
        fi

        # 完美匹配你的 32 字符 Tun2Socks 全局代理管理面板模板
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}   Tun2Socks 全局代理管理面板    ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status_show"
        echo -e "${GREEN}版本   :${RESET} $version_show"
        echo -e "${GREEN}代理   :${RESET} $port_show"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 Tun2Socks${RESET}"
        echo -e "${GREEN} 2. 更新 Tun2Socks${RESET}"
        echo -e "${GREEN} 3. 卸载 Tun2Socks${RESET}"
        echo -e "${GREEN} 4. 修改配置${RESET}"
        echo -e "${GREEN} 5. 启动 Tun2Socks${RESET}"
        echo -e "${GREEN} 6. 停止 Tun2Socks${RESET}"
        echo -e "${GREEN} 7. 重启 Tun2Socks${RESET}"
        echo -e "${GREEN} 8. 查看日志${RESET}"
        echo -e "${GREEN} 9. 测试当前出口IP${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        
        read -r -p "请选择: " sub_choice
        case "$sub_choice" in
            1|2) install_hev_tunnel && ok "操作完成。" ;;
            3) uninstall_hev_tunnel && ok "卸载成功。" ;;
            4) write_hev_config && rc-service "$HEV_SERVICE_NAME" restart && ok "配置已重载并重启。" ;;
            5) rc-service "$HEV_SERVICE_NAME" start ;;
            6) rc-service "$HEV_SERVICE_NAME" stop ;;
            7) rc-service "$HEV_SERVICE_NAME" restart ;;
            8) tail -n 20 /var/log/messages ;;
            9) test_hev_exit_ip ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# --- 主控制菜单入口 ---
while true; do
    clear
    get_status_info
    
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         CF-WARP 面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${panel_version}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}  1. 安装 WARP${RESET}"
    echo -e "${GREEN}  2. 更新 WARP${RESET}"
    echo -e "${GREEN}  3. 卸载 WARP${RESET}"
    echo -e "${GREEN}  4. 修改配置${RESET}"
    echo -e "${GREEN}  5. 启动 WARP${RESET}"
    echo -e "${GREEN}  6. 停止 WARP${RESET}"
    echo -e "${GREEN}  7. 重启 WARP${RESET}"
    echo -e "${GREEN}  8. 查看日志${RESET}"
    echo -e "${GREEN}  9. 查看配置与出口状态${RESET}"
    echo -e "${GREEN} 10.${RESET} ${YELLOW}谷歌分流${RESET}"
    echo -e "${GREEN} 11.${RESET} ${YELLOW}Tun2Socks全局出口${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    read -r -p "请输入您的选择: " main_choice
    case "$main_choice" in
        1) download_bin && register_usque && write_systemd "SOCKS5" "127.0.0.1" "1080" "" "" && ok "安装成功。" ;;
        2) download_bin && ok "更新完成。" ;;
        3) rc-service "$SERVICE_NAME" stop 2>/dev/null || true; rm -f "/etc/init.d/${SERVICE_NAME}" 2>/dev/null; ok "服务已彻底卸载。" ;;
        4) menu_edit_config ;;
        5) rc-service "$SERVICE_NAME" start ;;
        6) rc-service "$SERVICE_NAME" stop ;;
        7) rc-service "$SERVICE_NAME" restart ;;
        8) tail -n 20 /var/log/messages ;;
        9) menu_show_node_config ;;
        10) menu_transparent_proxy_center ;;
        11) menu_hev_tunnel_center ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
done
