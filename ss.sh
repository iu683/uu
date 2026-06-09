#!/usr/bin/env bash
set -e

# ==============================================================================
#   Usque (MASQUE-WARP) 全能综合控制面板 (Alpine Linux 终极完美重构版)
# ==============================================================================

# --- 核心主程序变量 ---
export REPO_USQUE="Diniboy1123/usque"
export SERVICE_NAME="usque"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 模块一：Redsocks 透明代理专属变量 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_SERVICE_FILE="/etc/init.d/${PROXY_SERVICE_NAME}"

# --- 模块二：Hev-Socks5-Tunnel 专属变量 ---
export HEV_REPO="heiher/hev-socks5-tunnel"
export HEV_SERVICE_NAME="tun2socks"
export HEV_SERVICE_FILE="/etc/init.d/tun2socks"
export HEV_CONFIG_DIR="/etc/tun2socks"
export HEV_CONFIG_FILE="${HEV_CONFIG_DIR}/config.yaml"
export HEV_BIN="/usr/local/bin/tun2socks"

# 配色方案
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\1;33m'
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

info() { echo -e "${BLUE}[信息]${RESET} $1"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $1"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $1"; }
die()  { echo -e "${RED}[错误]${RESET} $1" >&2; exit 1; }
step() { echo -e "${PURPLE}[步骤]${RESET} $1"; }

# --- Alpine 专属依赖环境预检 ---
check_deps() {
    local missing_deps=""
    if ! command -v unzip >/dev/null 2>&1; then missing_deps="$missing_deps unzip"; fi
    if ! command -v ip >/dev/null 2>&1; then missing_deps="$missing_deps iproute2"; fi
    if ! command -v curl >/dev/null 2>&1; then missing_deps="$missing_deps curl"; fi
    if ! command -v ss >/dev/null 2>&1; then missing_deps="$missing_deps iproute2"; fi

    if [ -n "$missing_deps" ]; then
        warn "未检测到必要组件，正在尝试通过 apk 自动补齐: $missing_deps..."
        apk update -q && apk add -q unzip iproute2 curl bash iptables || die "组件缺失且自动安装失败，请手动执行 apk add 补齐。"
    fi
    # 强制确保底层 tun 驱动就绪
    if [ ! -c /dev/net/tun ]; then
        modprobe tun 2>/dev/null || true
        echo "tun" >> /etc/modules 2>/dev/null || true
    fi
}

# --- 强制物理清场函数（解决各种死锁、残留、already running 矛盾） ---
force_kill_and_zap() {
    local name="$1"
    info "正在对 ${name} 执行强力物理清场..."
    rc-service "$name" stop >/dev/null 2>&1 || true
    
    case "$name" in
        "usque")
            killall -9 usque 2>/dev/null || true
            rm -f /run/usque.pid
            ;;
        "usque-google-proxy")
            killall -9 redsocks redsocks2 2>/dev/null || true
            rm -f /run/usque-google-proxy.pid /run/redsocks.pid
            ;;
        "tun2socks")
            killall -9 tun2socks 2>/dev/null || true
            rm -f /run/tun2socks.pid
            ;;
    esac

    # 强行粉碎 OpenRC 的状态锁残余
    rm -rf "/run/openrc/daemons/${name}" "/run/openrc/started/${name}" 2>/dev/null || true
    rc-service "$name" zap >/dev/null 2>&1 || true
}

cleanup_ip_rules() {
    step "正在清洗底层残留的 IP 规则和策略路由..."
    /sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
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
    
    # 彻底抹除免流置顶规则
    local remote_endpoint=$(grep -o '"endpoint": *"[^"]*"' "$CONF_FILE" 2>/dev/null | awk -F '"' '{print $4}' | awk -F ':' '{print $1}')
    if [ -n "$remote_endpoint" ]; then
        /sbin/ip rule del to "${remote_endpoint}" lookup main pref 3 2>/dev/null || true
    fi
    ok "策略路由及规则清洗完毕。"
}

# --- DNS64/网络加速工具函数 ---
test_dns64_server() {
    local dns_server=$1
    if ping6 -c 2 -W 2 "$dns_server" &>/dev/null; then return 0; else return 1; fi
}

test_github_access() {
    if curl -s -I -m 6 https://github.com >/dev/null; then return 0; else return 1; fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    local was_immutable=$3
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
        if [ "$was_immutable" = true ]; then chattr +i "$resolv_conf" || true; fi
    fi
}

set_dns64_servers() {
    local resolv_conf=$1
    local was_immutable=$2
    local resolv_conf_bak=$3
    
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
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    return 1
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

    force_kill_and_zap "$SERVICE_NAME"
    rm -f "$INSTALL_BIN"

    info "正在检索 Usque 最新版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO_USQUE}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done

    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"
    info "准备下载版本: v${pure_ver}"

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
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then has_v4=1; fi

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    info "正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        ok "Cloudflare 本地注册成功。"
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            [ -z "$v6_ep" ] && v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
        fi
    else
        die "注册失败。请确保你的 VPS 拥有 IPv6 出网能力。"
    fi
}

# --- 3. 写入 OpenRC 服务 ---
write_openrc_service() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u ${user} -w ${pass}"

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
description="Usque WARP SOCKS5/HTTP Gateway"
supervisor="supervise-daemon"
command="${INSTALL_BIN}"
command_args="--config ${CONF_FILE} ${args}"
working_directory="${CONF_DIR}"
depend() { need net; after firewall; }
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

# --- 4. 状态获取 (抛弃 OpenRC 检查，真机视显) ---
get_status_info() {
    if pgrep -f "usque" >/dev/null; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

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
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"

    echo -e "==== [修改监听配置] ===="
    echo "1. SOCKS5 模式"
    echo "2. HTTP 模式"
    read -r -p "选择模式 [当前: $o_mode]: " m_choice
    case "$m_choice" in 1) n_mode="SOCKS5" ;; 2) n_mode="HTTP" ;; *) n_mode="$o_mode" ;; esac

    read -r -p "监听 IP [当前: $o_ip]: " n_ip; n_ip="${n_ip:-$o_ip}"
    read -r -p "监听端口 [当前: $o_port]: " n_port; n_port="${n_port:-$o_port}"
    
    read -r -p "用户名 [当前: ${o_user:-空}]: " i_user
    if [ -z "$i_user" ]; then n_user="$o_user"; elif [ "$i_user" = "clear" ]; then n_user=""; else n_user="$i_user"; fi

    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then n_pass="$o_pass"; elif [ "$i_pass" = "clear" ]; then n_pass=""; else n_pass="$i_pass"; fi

    force_kill_and_zap "$SERVICE_NAME"
    write_openrc_service "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" start && ok "配置已更新并重启服务。"
}

# --- 6. 验证核心出境 ---
menu_show_node_config() {
    [ -f "$META_FILE" ] || die "记录不存在。"
    local b_mode b_ip b_port b_user b_pass
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"

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
        warn "验证失败，请确认后端核心状态。"
    fi
}

# ==============================================================================
#   模块一：Google 透明代理专属控制中心
# ==============================================================================
start_transparent_proxy() {
    if pgrep redsocks >/dev/null; then warn "Google 透明代理已经在运行中。"; return; fi
    if ! pgrep usque >/dev/null; then warn "核心 WARP 未启动！请先开启主核心服务。"; return; fi

    local warp_port="1080"
    if [ -f "$META_FILE" ]; then IFS='|' read -r _ _ warp_port _ _ < "$META_FILE"; fi

    info "正在安装透明代理组件 (redsocks / iptables)..."
    apk add -q redsocks iptables

    info "正在优化并黑洞 Google IPv6 路由解析..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

    cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port}; type = socks5; }
EOF

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19"
if [ "$ACTION" = "start" ]; then
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do /sbin/iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345; done
    /sbin/iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || /sbin/iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    # Alpine 官方编译的 redsocks 路径实际位于 /usr/bin/redsocks
    cat <<EOF > "$PROXY_SERVICE_FILE"
#!/sbin/openrc-run
description="Cloudflare WARP Google Transparent Proxy (Redsocks Engine)"
supervisor="supervise-daemon"
command="/usr/bin/redsocks"
command_args="-c ${REDSOCKS_CONF}"
start_post() { ${PROXY_RULES_SCRIPT} start; }
stop_pre() { ${PROXY_RULES_SCRIPT} stop; }
EOF
    chmod +x "$PROXY_SERVICE_FILE"
    
    force_kill_and_zap "$PROXY_SERVICE_NAME"
    rc-update add "$PROXY_SERVICE_NAME" default >/dev/null 2>&1
    rc-service "$PROXY_SERVICE_NAME" start
    sleep 1
    ok "Google 分流规则已挂载。"
}

stop_transparent_proxy() {
    force_kill_and_zap "$PROXY_SERVICE_NAME"
    rc-update del "$PROXY_SERVICE_NAME" default >/dev/null 2>&1 || true
    [ -f "$PROXY_RULES_SCRIPT" ] && "$PROXY_RULES_SCRIPT" "stop" >/dev/null 2>&1 || true
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
    /sbin/ip -6 route del blackhole 2607:f8b0::/32 2>/dev/null || true
    ok "Google 透明分流已彻底关闭并物理断开。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 透明代理链路核验 =========${RESET}"
    if ! ss -lnpt | grep -q "12345"; then
        echo -e "   Redsocks 监听: ${RED}✘ 未在运行${RESET}"
        echo -e "   连通性测试结果: ${RED}✘ 已物理断开恢复直连${RESET}"
        return
    fi
    local http_status=$(curl -o /dev/null -s -w "%{http_code}" --socks5-hostname 127.0.0.1:12345 --max-time 5 "https://www.google.com" || echo "000")
    if [ "$http_status" -eq 200 ]; then
        echo -e "   分流连通状态: ${GREEN}✔ 拦截分流成功 (HTTP 200)${RESET}"
    else
        echo -e "   分流连通状态: ${RED}✘ 异常 (状态码: ${http_status})${RESET}"
    fi
    echo -e "${CYAN}====================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if pgrep redsocks >/dev/null; then proxy_status="${GREEN}运行中 (分流 Google 流量)${RESET}"; fi
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "    Google 透明代理管理控制菜单 (Alpine)  "
        echo -e "====================================="
        echo -e "当前状态 : $proxy_status"
        echo -e "====================================="
        echo "1. 开启 Google 分流"
        echo "2. 关闭 Google 分流"
        echo "3. 查看并验证代理连通性"
        echo "0. 返回主菜单"
        echo -e "====================================="
        read -r -p "请输入子选项: " sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) stop_transparent_proxy ;;
            3) verify_transparent_proxy ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#   模块二：Hev-Socks5-Tunnel 全局虚拟网卡三层控制中心 (真机解锁无死锁)
# ==============================================================================
write_hev_config() {
    mkdir -p "$HEV_CONFIG_DIR"
    local current_addr="127.0.0.1" current_port="1080" current_user="" current_pass=""
    if [ -f "$META_FILE" ]; then IFS='|' read -r _ current_addr current_port current_user current_pass < "$META_FILE"; fi

    read -r -p "请输入Socks5服务器地址 [$current_addr]: " input_addr; input_addr="${input_addr:-$current_addr}"
    read -r -p "请输入Socks5服务器端口 [$current_port]: " input_port; input_port="${input_port:-$current_port}"
    read -r -p "请输入用户名 (保持留空回车，清空输入 none) [${current_user:-无}]: " input_user; input_user="${input_user:-$current_user}"; [ "$input_user" = "none" ] && input_user=""
    read -r -p "请输入密码 (保持留空回车，清空输入 none) [${current_pass:-无}]: " input_pass; input_pass="${input_pass:-$current_pass}"; [ "$input_pass" = "none" ] && input_pass=""

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
    force_kill_and_zap "$HEV_SERVICE_NAME"
    cleanup_ip_rules
    rm -f "$HEV_BIN"

    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak" WAS_IMMUTABLE=false
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then chattr -i "$RESOLV_CONF" || true; WAS_IMMUTABLE=true; fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK" || true

    step "正在拉取 Tun2Socks 官方核心..."
    local latest_version="" DOWNLOAD_URL=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_version=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            DOWNLOAD_URL="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            break
        fi
    done
    [ -z "$latest_version" ] && DOWNLOAD_URL="https://github.com/$HEV_REPO/releases/download/v2.6.8/hev-socks5-tunnel-linux-x86_64"

    curl -L -f -o "$HEV_BIN" "$DOWNLOAD_URL"
    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    chmod +x "$HEV_BIN"

    write_hev_config

    local remote_endpoint=$(grep -o '"endpoint": *"[^"]*"' "$CONF_FILE" 2>/dev/null | awk -F '"' '{print $4}' | awk -F ':' '{print $1}')
    local RULE_BYPASS_CF=""
    if [ -n "$remote_endpoint" ]; then RULE_BYPASS_CF="/sbin/ip rule add to ${remote_endpoint} lookup main pref 3"; fi

    # 编写具备自愈性防御的网络挂载脚本
    cat <<EOF > "$HEV_SERVICE_FILE"
#!/sbin/openrc-run
description="Tun2Socks Hev Tunnel Routing Service"
supervisor="supervise-daemon"
command="${HEV_BIN}"
command_args="${HEV_CONFIG_FILE}"

start_post() {
    /bin/sleep 1
    /sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
    ${RULE_BYPASS_CF} 2>/dev/null || true
    /sbin/ip rule add fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route add default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule add lookup 20 pref 20 2>/dev/null || true
    /sbin/ip rule add to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule add to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule add to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule add to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
}
stop_post() {
    /sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
    [ -n "${remote_endpoint}" ] && /sbin/ip rule del to ${remote_endpoint} lookup main pref 3 2>/dev/null || true
    /sbin/ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route del default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule del lookup 20 pref 20 2>/dev/null || true
    /sbin/ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    /sbin/ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
}
EOF
    chmod +x "$HEV_SERVICE_FILE"
    rc-update add "$HEV_SERVICE_NAME" default >/dev/null 2>&1
    rc-service "$HEV_SERVICE_NAME" start
    ok "Tun2Socks 环境部署完毕。"
}

uninstall_hev_tunnel() {
    force_kill_and_zap "$HEV_SERVICE_NAME"
    cleanup_ip_rules
    rc-update del "$HEV_SERVICE_NAME" default >/dev/null 2>&1 || true
    rm -f "$HEV_SERVICE_FILE" "$HEV_BIN"
    rm -rf "$HEV_CONFIG_DIR"
    ok "全局三层网卡托管已被物理卸载洗净。"
}

test_hev_exit_ip() {
    step "正在拉取三层全局出口真实落地 IP..."
    local ip_info=$(curl --noproxy "*" -s -m 8 "https://api.ipify.org?format=json" || echo "")
    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        echo -e " 落地真实出口数据: ${YELLOW}$ip_info${RESET}"
        echo -e "${GREEN}----------------------------------------${RESET}"
    else
        warn "全局握手超时！请检查主核心是否正常运行。"
    fi
}

menu_hev_tunnel_center() {
    while true; do
        clear
        local status_show="${RED}未运行${RESET}"
        if pgrep -f "tun2socks" >/dev/null && ip link show tun0 >/dev/null 2>&1; then status_show="${GREEN}运行中 (全局托管中)${RESET}"; fi
        
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "     Tun2Socks 全局代理管理面板 (Alpine)  "
        echo -e "====================================="
        echo -e "当前状态 : $status_show"
        echo -e "====================================="
        echo "1. 安装/启动 Tun2Socks 全局托管"
        echo "2. 彻底关闭/卸载 全局托管网卡"
        echo "3. 测试全局出口落地状态"
        echo "0. 返回主菜单"
        echo -e "====================================="
        read -r -p "请输入子选项: " sub_choice
        case "$sub_choice" in
            1) install_hev_tunnel ;;
            2) uninstall_hev_tunnel ;;
            3) test_hev_exit_ip ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#   主控制网
# ==============================================================================
main_menu() {
    while true; do
        clear
        get_status_info
        echo -e "${CYAN}=====================================================${RESET}"
        echo -e "     Usque (MASQUE-WARP) 控制面板 [Alpine Linux 版]    "
        echo -e "${CYAN}=====================================================${RESET}"
        echo -e " 核心状态: $panel_status        核心版本: $panel_version"
        echo -e " 监听出口: $panel_port"
        echo -e "${CYAN}=====================================================${RESET}"
        echo -e "${YELLOW}[核心管理]${RESET}"
        echo "  1. 匿名注册并拉取安装最新 Usque 核心"
        echo "  2. 启动核心代理服务"
        echo "  3. 停止核心代理服务"
        echo "  4. 修改核心监听配置 (Socks5/HTTP/密码)"
        echo "  5. 验证核心出境握手"
        echo -e "-----------------------------------------------------"
        echo -e "${YELLOW}[高级分流进阶中心]${RESET}"
        echo -e "  10. 进入 ${PURPLE}Google 透明分流代理控制台${RESET}"
        echo -e "  11. 进入 ${PURPLE}Tun2Socks 全局虚拟网卡托管台${RESET}"
        echo "  0. 退出脚本"
        echo -e "${CYAN}=====================================================${RESET}"
        read -r -p "请输入选项 [0-11]: " main_choice
        case "$main_choice" in
            1) download_bin && register_usque && write_openrc_service "SOCKS5" "127.0.0.1" "1080" "" "" && rc-service "$SERVICE_NAME" start ;;
            2) force_kill_and_zap "$SERVICE_NAME" && rc-service "$SERVICE_NAME" start && ok "服务已拉起。" ;;
            3) force_kill_and_zap "$SERVICE_NAME" && ok "服务已停止。" ;;
            4) menu_edit_config ;;
            5) menu_show_node_config ;;
            10) menu_transparent_proxy_center ;;
            11) menu_hev_tunnel_center ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "请输入正确的选项！" && sleep 1 ;;
        esac
        [ "$main_choice" -ne 10 ] && [ "$main_choice" -ne 11 ] && read -n 1 -s -r -p "按任意键继续..."
    done
}

check_deps
main_menu
