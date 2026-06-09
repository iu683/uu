#!/usr/bin/env bash
# ==============================================================================
#    Usque (MASQUE-WARP) Alpine Linux 专属全能控制面板 (终极防环路版)
# ==============================================================================

# --- 核心主程序变量 ---
export REPO_USQUE="Diniboy1123/usque"
export SERVICE_NAME="usque"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_INIT_FILE="/etc/init.d/${SERVICE_NAME}"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 模块一：Redsocks 谷歌透明代理专属变量 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_INIT_FILE="/etc/init.d/${PROXY_SERVICE_NAME}"

# --- 模块二：Hev-Socks5-Tunnel 专属变量 ---
export HEV_REPO="heiher/hev-socks5-tunnel"
export HEV_SERVICE_NAME="tun2socks"
export HEV_INIT_FILE="/etc/init.d/tun2socks"
export HEV_CONFIG_DIR="/etc/tun2socks"
export HEV_CONFIG_FILE="${HEV_CONFIG_DIR}/config.yaml"
export HEV_BIN="/usr/local/bin/tun2socks"
export HEV_LOG_FILE="/var/log/tun2socks.log"

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

# 强制断言 Alpine 环境
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "alpine" ]; then
        echo -e "${RED}[错误]${RESET} 本脚本已重构为 Alpine Linux 专属，检测到当前系统为 $ID，拒绝运行。" && exit 1
    fi
else
    echo -e "${RED}[错误]${RESET} 无法识别的 OS 架构，请在 Alpine Linux 中运行。" && exit 1
fi

info() { echo -e "${BLUE}[信息]${RESET} $1"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $1"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $1"; }
die()  { echo -e "${RED}[错误]${RESET} $1" >&2; exit 1; }

# --- 基础依赖环境预检 ---
check_deps() {
    local missing_deps=""
    local pkgs="unzip iproute2 curl bash iptables ip6tables grep gawk sed redsocks net-tools"
    
    for pkg in $pkgs; do
        if ! apk info -e $pkg >/dev/null; then
            missing_deps="$missing_deps $pkg"
        fi
    done

    if [ -n "$missing_deps" ]; then
        info "检测到缺少必要组件，正在补充安装..."
        apk update -q
        apk add -q --no-cache $missing_deps || die "依赖安装失败，请检查 Alpine apk源。"
    fi

    if [ -f /usr/bin/gawk ] && [ ! -f /usr/bin/awk ]; then
        ln -sf /usr/bin/gawk /usr/bin/awk
    fi
}

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
    if [ -f "$resolv_conf_bak" ]; then mv "$resolv_conf_bak" "$resolv_conf"; fi
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
    restore_dns_config "$resolv_conf" "$resolv_conf_bak"
    return 1
}

cleanup_ip_rules() {
    local ip_bin="/sbin/ip"
    local ip6_bin="/sbin/ip"
    [ ! -f "$ip_bin" ] && ip_bin=$(which ip 2>/dev/null)
    [ ! -f "$ip6_bin" ] && ip6_bin=$(which ip6 2>/dev/null || which ip 2>/dev/null)

    # 清理优选 IP 豁免直连路由
    $ip_bin route del 162.159.192.1 2>/dev/null || true
    $ip_bin route del 162.159.192.1 table 20 2>/dev/null || true
    $ip_bin route del 127.0.0.1 table 20 2>/dev/null || true

    $ip_bin rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    $ip6_bin rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    $ip_bin route del default dev tun0 table 20 2>/dev/null || true
    $ip_bin rule del lookup 20 pref 20 2>/dev/null || true
    $ip_bin rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    $ip_bin rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    $ip_bin rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    $ip_bin rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true

    while $ip_bin rule del pref 15 2>/dev/null; do true; done
    while $ip6_bin rule del pref 15 2>/dev/null; do true; done
    while $ip_bin rule del pref 5 2>/dev/null; do true; done
    while $ip6_bin rule del pref 5 2>/dev/null; do true; done
}

# --- 1. 安装 / 2. 更新 ---
download_bin() {
    check_deps
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac

    info "正在检索最新版本..."
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
    
    local has_v4=0
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then has_v4=1; fi
    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    if "${INSTALL_BIN}" register; then
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            [ -z "$v6_ep" ] && v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
        fi
        sed -i 's/"endpoint_v4": *"[^"]*"/"endpoint_v4": "162.159.192.1:2408"/g' "$CONF_FILE" 2>/dev/null || true
        ok "WARP 安装/更新并注册成功，已强制启用 162.159.192.1 优选端点。"
        
        info "正在执行 WARP 自动初始化启动..."
        write_systemd "SOCKS5" "127.0.0.1" "1080" "" ""
        rc-service "$SERVICE_NAME" start && ok "WARP 守护进程已成功激活运行！"
    else
        warn "注册失败，请检查网络。"
    fi
}

# --- 3. 卸载 WARP ---
uninstall_all() {
    cleanup_ip_rules
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
    rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1
    rc-update del "$PROXY_SERVICE_NAME" default >/dev/null 2>&1
    rc-service tun2socks stop >/dev/null 2>&1
    rc-update del tun2socks default >/dev/null 2>&1
    
    rm -f "$INSTALL_BIN" "$SERVICE_INIT_FILE" "$PROXY_INIT_FILE" "$HEV_INIT_FILE" "$HEV_BIN" "$HEV_LOG_FILE"
    rm -rf "$CONF_DIR" "$DATA_DIR" "$HEV_CONFIG_DIR"
    ok "WARP 已完全卸载清除。"
}

# --- 4. 修改配置 ---
write_systemd() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u ${user} -w ${pass}"

    cat <<EOF > "$SERVICE_INIT_FILE"
#!/sbin/openrc-run
description="Usque WARP SOCKS5/HTTP Gateway"
supervisor="supervise-daemon"
command="${INSTALL_BIN}"
command_args="--config ${CONF_FILE} ${args}"
command_background="true"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after firewall; }
EOF
    chmod +x "$SERVICE_INIT_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

menu_edit_config() {
    local o_mode="SOCKS5" o_ip="127.0.0.1" o_port="1080" o_user="" o_pass=""
    if [ -f "$META_FILE" ]; then IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"; fi

    echo -e "==== [修改监听配置] ===="
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
    if [ -z "$i_user" ]; then n_user="$o_user"; elif [ "$i_user" = "none" ]; then n_user=""; else n_user="$i_user"; fi

    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then n_pass="$o_pass"; elif [ "$i_pass" = "none" ]; then n_pass=""; else n_pass="$i_pass"; fi

    write_systemd "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" restart && ok "配置已更新并重启服务。"
}

# --- 获取状态 ---
get_status_info() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
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

view_logs() {
    if [ -f /var/log/messages ]; then tail -n 50 /var/log/messages | grep usque; else echo "未找到系统核心日志。"; fi
}

menu_show_node_config() {
    if [ -f "$META_FILE" ]; then
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

        # 绕过系统虚拟网卡强制使用本地 SOCKS5 端口测试 WARP 连通性
        if curl -sS --max-time 6 -x "$p_url" "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp="; then
            ok "验证成功！WARP 已开启。"
        else
            warn "验证失败，请检查服务状态。"
        fi
    else
        warn "未配置任何节点信息。"
    fi
}

# ==============================================================================
#    模块一：Google 透明代理 (增加主动连通性测试验证)
# ==============================================================================
get_google_proxy_status() {
    local rc_ok=0
    local port_ok=0
    local ipt_ok=0

    if rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1; then rc_ok=1; fi
    if netstat -tuln 2>/dev/null | grep -q ":12345 "; then port_ok=1; fi
    if iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "WARP_GOOGLE"; then ipt_ok=1; fi

    if [ "$rc_ok" -eq 1 ] && [ "$port_ok" -eq 1 ] && [ "$ipt_ok" -eq 1 ]; then
        echo -e "${GREEN}运行中${RESET}"
    elif [ "$rc_ok" -eq 0 ] && [ "$port_ok" -eq 0 ] && [ "$ipt_ok" -eq 0 ]; then
        echo -e "${RED}未运行${RESET}"
    else
        echo -e "${YELLOW}状态异常 (正在自动修复锁...)${RESET}"
        rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1
    fi
}

test_google_proxy_connectivity() {
    info "正在对 Google 分流路由执行全链路拦截核验..."
    # 强制不使用任何应用层代理，完全交由系统 net nat 拦截
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 "https://www.google.com" || echo "000")
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 301 ] || [ "$http_code" -eq 302 ]; then
        ok "谷歌分流拦截测试成功！HTTP 状态码: $http_code (已成功经由 Redsocks 拦截分流)"
    else
        warn "谷歌分流测试失败，外部链接受阻或透明拦截未完全合流。错误代码: $http_code"
    fi
}

start_transparent_proxy() {
    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then warn "WARP 未运行！请先激活主服务。"; return; fi
    local warp_port="1080"
    if [ -f "$META_FILE" ]; then IFS='|' read -r _ _ warp_port _ _ < "$META_FILE"; fi

    check_deps
    /sbin/ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

    cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port}; type = socks5; }
EOF

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
IPTABLES_BIN=$(which iptables 2>/dev/null || echo "/usr/sbin/iptables")
GOOGLE_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19"
if [ "$ACTION" = "start" ]; then
    $IPTABLES_BIN -t nat -N WARP_GOOGLE 2>/dev/null
    $IPTABLES_BIN -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do
        $IPTABLES_BIN -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345 2>/dev/null
    done
    $IPTABLES_BIN -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || $IPTABLES_BIN -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    $IPTABLES_BIN -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    $IPTABLES_BIN -t nat -F WARP_GOOGLE 2>/dev/null
    $IPTABLES_BIN -t nat -X WARP_GOOGLE 2>/dev/null
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    cat <<EOF > "$PROXY_INIT_FILE"
#!/sbin/openrc-run
description="Cloudflare WARP Google Transparent Proxy"
supervisor="supervise-daemon"
command="/usr/bin/redsocks"
command_args="-c ${REDSOCKS_CONF}"
pidfile="/run/\${RC_SVCNAME}.pid"
start_post() { ${PROXY_RULES_SCRIPT} start; }
stop_pre() { ${PROXY_RULES_SCRIPT} stop; }
EOF
    chmod +x "$PROXY_INIT_FILE"
    rc-update add "$PROXY_SERVICE_NAME" default >/dev/null 2>&1
    
    rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1
    rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1
    killall -9 redsocks >/dev/null 2>&1
    sleep 0.5
    
    rc-service "$PROXY_SERVICE_NAME" start && ok "谷歌分流已开启。"
    test_google_proxy_connectivity
}

stop_transparent_proxy() {
    rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1
    rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1
    rc-update del "$PROXY_SERVICE_NAME" default >/dev/null 2>&1
    killall -9 redsocks >/dev/null 2>&1
    ok "谷歌分流已关闭。"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status=$(get_google_proxy_status)
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}      Google透明代理管理控制菜单     ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "当前状态 : $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "1. 开启Google分流"
        echo -e "2. 关闭Google分流"
        echo -e "3. 测试验证分流状态"
        echo -e "0. 返回主菜单"
        echo -e "${GREEN}=====================================${RESET}"
        read -r -p "请输入子选项: " sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) stop_transparent_proxy ;;
            3) test_google_proxy_connectivity ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#    模块二：Hev-Socks5-Tunnel 控制中心 (深度修复升级版)
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

    # 兜底默认值
    [ -z "$current_addr" ] && current_addr="127.0.0.1"
    [ -z "$current_port" ] && current_port="1080"

    local input_addr
    while true; do
        read -r -p "请输入Socks5服务器地址 [$current_addr]: " input_addr
        input_addr="${input_addr:-$current_addr}"
        if [ -n "$input_addr" ]; then break; else warn "地址不能为空。"; fi
    done

    local input_port
    while true; do
        read -r -p "请输入Socks5服务器端口 [$current_port]: " input_port
        input_port="${input_port:-$current_port}"
        if [[ "$input_port" =~ ^[0-9]+$ ]]; then break; else warn "请输入合规端口。"; fi
    done

    read -r -p "请输入用户名 (保持回车，清空输入 none) [${current_user:-无}]: " input_user
    input_user="${input_user:-$current_user}"
    [ "$input_user" = "none" ] && input_user=""

    local input_pass=""
    if [ -n "$input_user" ]; then
        read -r -p "请输入密码 (保持回车，清空输入 none) [${current_pass:-无}]: " input_pass
        input_pass="${input_pass:-$current_pass}"
        [ "$input_pass" = "none" ] && input_pass=""
    fi

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

change_hev_config() {
    write_hev_config
    if rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$HEV_SERVICE_NAME" restart && ok "配置已重新挂载生效。"
    fi
}

update_hev_core() {
    if [ ! -f "$HEV_BIN" ]; then warn "尚未检测到 Tun2Socks 运行环境。"; return 1; fi
    local latest_version="" download_url=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            download_url="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            break
        fi
    done

    [ -z "$latest_version" ] && { warn "无法检索到 Tun2Socks 最新版本。"; return 1; }
    local is_running=false
    if rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1; then is_running=true; rc-service "$HEV_SERVICE_NAME" stop; fi

    if curl -L -f -o "$HEV_BIN" "$download_url"; then
        chmod +x "$HEV_BIN"
        ok "Hev-Tunnel 核心程序演进成功！版本: $latest_version"
    else
        warn "核心升级文件下载失败。"
    fi
    if [ "$is_running" = true ]; then rc-service "$HEV_SERVICE_NAME" start; fi
}

install_hev_tunnel() {
    cleanup_ip_rules
    if rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1; then rc-service "$HEV_SERVICE_NAME" stop; fi

    local DEFAULT_GATEWAY=$(/sbin/ip route show default | grep -v tun0 | awk '{print $3}' | head -n1)
    if [ -z "$DEFAULT_GATEWAY" ]; then
        die "未能检测到系统默认物理网关！请确保物理网卡已联网。"
    fi

    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true
    set_dns64_servers "$RESOLV_CONF" "false" "$RESOLV_CONF_BAK"

    local latest_version="" download_url=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            download_url="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            break
        fi
    done

    [ -z "$download_url" ] && download_url="https://github.com/$HEV_REPO/releases/download/v2.7.2/hev-socks5-tunnel-linux-x86_64"

    info "开始下载 Tun2Socks 核心引擎..."
    curl -L -f -o "$HEV_BIN" "$download_url" || die "核心组件下载失败。"
    chmod +x "$HEV_BIN"
    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK"
    write_hev_config

    local WARP_PORT="1080"
    if [ -f "$META_FILE" ]; then IFS='|' read -r _ _ WARP_PORT _ _ < "$META_FILE"; fi

    # 自动生成的 OpenRC 启动脚本，修复重定向标准输出注入独立日志
    cat <<EOF > "$HEV_INIT_FILE"
#!/sbin/openrc-run
description="Tun2Socks Engine"
supervisor="supervise-daemon"
command="$HEV_BIN"
command_args="$HEV_CONFIG_FILE"
output_log="$HEV_LOG_FILE"
error_log="$HEV_LOG_FILE"
pidfile="/run/\${RC_SVCNAME}.pid"
start_post() {
    sleep 1
    /sbin/ip route add 162.159.192.1 via ${DEFAULT_GATEWAY} pref 1 2>/dev/null || true
    /sbin/ip route add 162.159.192.1 via ${DEFAULT_GATEWAY} table 20 2>/dev/null || true
    /sbin/ip route add 127.0.0.1 via ${DEFAULT_GATEWAY} table 20 2>/dev/null || true

    /sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
    /sbin/ip rule add to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4 2>/dev/null || true
    /sbin/ip rule add fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route add default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule add lookup 20 pref 20 2>/dev/null || true
}
stop_post() {
    /sbin/ip rule del lookup 20 pref 20 2>/dev/null || true
    /sbin/ip route del default dev tun0 table 20 2>/dev/null || true
    /sbin/ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    /sbin/ip route del 162.159.192.1 2>/dev/null || true
    /sbin/ip route del 162.159.192.1 table 20 2>/dev/null || true
    /sbin/ip route del 127.0.0.1 table 20 2>/dev/null || true
}
EOF
    chmod +x "$HEV_INIT_FILE"
    rc-update add tun2socks default >/dev/null 2>&1
    
    rc-service tun2socks stop >/dev/null 2>&1
    rc-service tun2socks zap >/dev/null 2>&1
    
    rc-service tun2socks start && ok "Tun2Socks 虚拟环境成功上线，防回环路由规则已激活！"
}

uninstall_hev_tunnel() {
    cleanup_ip_rules
    rc-service tun2socks stop >/dev/null 2>&1
    rc-service tun2socks zap >/dev/null 2>&1
    rc-update del tun2socks default >/dev/null 2>&1
    rm -f "$HEV_INIT_FILE" "$HEV_BIN" "$HEV_LOG_FILE"
    rm -rf "$HEV_CONFIG_DIR"
    ok "Tun2Socks 组件已完全卸载。"
}

test_hev_exit_ip() {
    info "正在通过虚拟网卡发起全球端点测速与落地核验..."
    # 移除有歧义的 --noproxy 绕过参数，直接使用外部 API 验证
    local ip_info=$(curl -s -m 8 "https://api.ipify.org?format=json" 2>/dev/null || echo "")
    if [ -n "$ip_info" ]; then 
        echo -e "${GREEN}落地出口验证完美成功！${RESET}"
        echo -e "${GREEN}当前全局落地 IP: ${YELLOW}$ip_info${RESET}"
    else 
        local trace_info=$(curl -s -m 6 "http://104.26.12.31/cdn-cgi/trace" 2>/dev/null | grep -E "warp=|ip=")
        if [ -n "$trace_info" ]; then
            echo -e "${GREEN}落地出口验证完美成功！(通过 Cloudflare 边缘直连)\n${YELLOW}${trace_info}${RESET}"
        else
            warn "全局网卡出口测试超时或失败！请通过子菜单 [6] 检查 Tun2Socks 独立日志追溯问题。"
        fi
    fi
}

view_hev_logs() {
    if [ -f "$HEV_LOG_FILE" ]; then
        echo -e "\n========= Tun2Socks 运行日志 (最后50行) ========="
        tail -n 50 "$HEV_LOG_FILE"
        echo "=================================================="
    else
        warn "未找到 Tun2Socks 专属日志文件，可能服务尚未拉起或无输出。"
    fi
}

menu_hev_tunnel_center() {
    while true; do
        clear
        local status_show="${RED}已停止${RESET}"
        if rc-service tun2socks status >/dev/null 2>&1; then status_show="${GREEN}运行中${RESET}"; fi
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}       Tun2Socks 管理控制面板        ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "当前状态 : $status_show"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "1. 安装/重置 Tun2Socks 虚拟环境"
        echo -e "2. 卸载 Tun2Socks 虚拟网卡组件"
        echo -e "3. 修改对接分流节点配置"
        echo -e "4. 检测并演进核心版本"
        echo -e "5. 测试全局出口落地状态"
        echo -e "6. 查看 Tun2Socks 独立日志"
        echo -e "0. 返回主菜单"
        echo -e "${GREEN}=====================================${RESET}"
        read -r -p "请输入子选项: " hev_choice
        case "$hev_choice" in
            1) install_hev_tunnel ;;
            2) uninstall_hev_tunnel ;;
            3) change_hev_config ;;
            4) update_hev_core ;;
            5) test_hev_exit_ip ;;
            6) view_hev_logs ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#    主控台大循环入口
# ==============================================================================
main_menu() {
    while true; do
        get_status_info
        clear
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}         CF-WARP 面板          ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}状态 :${RESET} $panel_status"
        echo -e "${GREEN}version :${RESET} ${panel_version}"
        echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}  1. 安装 WARP${RESET}"
        echo -e "${GREEN}  2. 更新 WARP${RESET}"
        echo -e "${GREEN}  3. 卸载 WARP${RESET}"
        echo -e "${GREEN}  4. 修改配置${RESET}"
        echo -e "${GREEN}  5. 启动 WARP${RESET}"
        echo -e "${GREEN}  6. 停止 WARP${RESET}"
        echo -e "${GREEN}  7. 重启 WARP${RESET}"
        echo -e "${GREEN}  8. 查看主程序日志${RESET}"
        echo -e "${GREEN}  9. 查看配置与出口状态${RESET}"
        echo -e "${GREEN} 10.${RESET} ${YELLOW}谷歌分流${RESET}"
        echo -e "${GREEN} 11.${RESET} ${YELLOW}Tun2Socks全局出口${RESET}"
        echo -e "${GREEN}  0. 退出${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r choice
        
        case "$choice" in
            1|2) download_bin ;;
            3) uninstall_all ;;
            4) menu_edit_config ;;
            5) 
                if [ ! -f "$SERVICE_INIT_FILE" ]; then write_systemd "SOCKS5" "127.0.0.1" "1080" "" ""; fi
                rc-service "$SERVICE_NAME" start && ok "WARP 已启动。" 
                ;;
            6) rc-service "$SERVICE_NAME" stop && ok "WARP 已停止。" ;;
            7) 
                rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
                rc-service "$SERVICE_NAME" zap >/dev/null 2>&1
                killall -9 usque >/dev/null 2>&1
                sleep 0.5
                rc-service "$SERVICE_NAME" start && ok "WARP 已成功完成物理重置并拉起。" 
                ;;
            8) view_logs ;;
            9) menu_show_node_config ;;
            10) menu_transparent_proxy_center ;;
            11) menu_hev_tunnel_center ;;
            0) exit 0 ;;
            *) warn "无效选项。" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# 修正并唤醒执行主函数
main_menu
