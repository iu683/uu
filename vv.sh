#!/usr/bin/env bash
set -e

# ==============================================================================
#   Usque (MASQUE-WARP) 全能综合控制面板 (含 Google 透明代理 与 Tun2Socks 出口)
# ==============================================================================

# --- 核心主程序变量 ---
export REPO_USQUE="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 模块一：Redsocks 透明代理专属变量 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"

# --- 模块二：Hev-Socks5-Tunnel 专属变量 ---
export HEV_REPO="heiher/hev-socks5-tunnel"
export HEV_SERVICE_NAME="tun2socks"
export HEV_SERVICE_FILE="/etc/systemd/system/tun2socks.service"
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
NC='\033[0m'
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

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

info() { echo -e "${BLUE}[信息]${RESET} $1"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $1"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $1"; }
die()  { echo -e "${RED}[错误]${RESET} $1" >&2; exit 1; }
step() { echo -e "${PURPLE}[步骤]${RESET} $1"; }

# --- 基础依赖环境预检 ---
check_deps() {
    local missing_deps=""
    if ! command -v unzip >/dev/null 2>&1; then missing_deps="$missing_deps unzip"; fi
    if ! command -v ip >/dev/null 2>&1; then missing_deps="$missing_deps iproute2"; fi

    if [ -n "$missing_deps" ]; then
        warn "未检测到必要组件，正在尝试自动补齐: $missing_deps..."
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y unzip iproute2 >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora) yum install -y unzip iproute2 >/dev/null 2>&1 ;;
            *) die "组件缺失且无法自动安装，请手动安装 $missing_deps 后重试。" ;;
        esac
    fi
}

# --- DNS64/网络加速专属工具函数群 ---
test_dns64_server() {
    local dns_server=$1
    step "正在测试 DNS64 服务器 $dns_server 的连通性..."
    if ping6 -c 3 -W 2 "$dns_server" &>/dev/null; then
        info "DNS64 服务器 $dns_server 可达。"
        return 0
    else
        warn "DNS64 服务器 $dns_server 不可达。"
        return 1
    fi
}

test_github_access() {
    step "正在测试 GitHub 访问状态..."
    if curl -s -I -m 10 https://github.com >/dev/null; then
        ok "GitHub 访问测试成功。"
        return 0
    else
        warn "GitHub 访问测试失败。"
        return 1
    fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    local was_immutable=$3

    step "正在恢复原始 DNS 配置..."
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
        ok "DNS 配置已还原。"
        if [ "$was_immutable" = true ]; then
            info "正在重新锁定 /etc/resolv.conf..."
            chattr +i "$resolv_conf" || warn "无法重新锁定 /etc/resolv.conf。"
        fi
    else
        warn "未找到备份文件，无法自动恢复。"
        if [ "$was_immutable" = true ]; then
             chattr +i "$resolv_conf" || true
        fi
    fi
}

set_dns64_servers() {
    local resolv_conf=$1
    local was_immutable=$2
    local resolv_conf_bak=$3
    
    step "设置动态 DNS64 解析服务..."
    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    
    if test_github_access; then return 0; fi
    
    warn "主 DNS64 节点受阻，正在尝试轮询备用 DNS64 节点池..."
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then
                ok "成功通过备选 DNS64 [$dns_server] 连接到 GitHub。"
                return 0
            fi
        fi
    done
    
    warn "所有 DNS64 服务器测试失败，无法正常请求 GitHub 资源。"
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    return 1
}

cleanup_ip_rules() {
    step "正在强行清理底层残留的 IP 规则和旧三层路由..."
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true

    while ip rule del pref 15 2>/dev/null; do true; done
    while ip -6 rule del pref 15 2>/dev/null; do true; done
    while ip rule del pref 5 2>/dev/null; do true; done
    while ip -6 rule del pref 5 2>/dev/null; do true; done
    ok "高级策略路由及规则洗净完毕。"
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
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then
        has_v4=1
    fi

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    info "正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        ok "Cloudflare 本地注册成功。"
        
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            info "检测到纯 IPv6 环境，正在自动修正配置文件..."
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            if [ -z "$v6_ep" ]; then
                v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            fi
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
            ok "IPv6 修正已完成 (Endpoint: $v6_ep)。"
        fi
    else
        die "注册失败。提示：请确保你的 VPS 已开启 IPv6 外部访问能力。"
    fi
}

# --- 3. 写入服务 ---
write_systemd() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u \"${user}\" -w \"${pass}\""

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Usque WARP SOCKS5/HTTP
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CONF_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE} ${args}
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

# --- 4. 状态获取 ---
get_status_info() {
    systemctl is-active --quiet "$SERVICE_NAME" && panel_status="${YELLOW}运行中${RESET}" || panel_status="${RED}未运行${RESET}"
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
    systemctl restart "$SERVICE_NAME" && ok "配置已更新并重启服务。"
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
#   模块一：Google 透明代理专属控制中心 (iptables + redsocks)
# ==============================================================================
start_transparent_proxy() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明分流代理已经处于运行状态，无需重复启动。"
        return
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "核心 WARP-Rust 未在后台运行！请先开启主服务。"
        return
    fi

    local warp_ip="127.0.0.1" warp_port="1080" has_auth=""
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r _ warp_ip warp_port has_auth _ < "$META_FILE"
    fi

    if [ -n "$has_auth" ] && [ "$warp_ip" != "127.0.0.1" ] && [ "$warp_ip" != "localhost" ]; then
        warn "当前 WARP 节点开启了密码鉴权。透明分流暂不支持有密公网代理。"
        warn "建议在主菜单修改监听 IP 为 127.0.0.1 且不设密码后再试。"
        return
    fi

    info "正在安装透明代理核心组件 (redsocks / iptables)..."
    local proxy_missing=""
    if ! command -v redsocks &>/dev/null; then proxy_missing="$proxy_missing redsocks"; fi
    if ! command -v iptables &>/dev/null; then proxy_missing="$proxy_missing iptables"; fi

    if [ -n "$proxy_missing" ]; then
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y $proxy_missing >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then dnf install -y $proxy_missing >/dev/null 2>&1; else yum install -y $proxy_missing >/dev/null 2>&1; fi
                ;;
        esac
    fi

    if ! command -v redsocks &>/dev/null || ! command -v iptables &>/dev/null; then
        die "透明代理组件安装失败，请检查系统的源环境。"
    fi

    if systemctl is-enabled redsocks >/dev/null 2>&1 || systemctl is-active redsocks >/dev/null 2>&1; then
        systemctl stop redsocks >/dev/null 2>&1
        systemctl disable redsocks >/dev/null 2>&1
    fi

    info "正在阻断并优化 Google IPv6 路由解析..."
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
    systemctl start "$PROXY_SERVICE_NAME"
    
    sleep 1.5
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        ok "Google 透明分流代理已成功挂载！"
    else
        warn "透明代理异常，实时崩溃日志如下："
        journalctl -u "$PROXY_SERVICE_NAME" -n 15 --no-pager
    fi
}

stop_transparent_proxy() {
    if ! systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明代理原本就处于关闭状态。"
        return
    fi
    systemctl stop "$PROXY_SERVICE_NAME"
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    ok "Google 透明代理已安全停止，劫持网链已卸载。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 透明代理链路深度验证 =========${RESET}"
    if command -v iptables &>/dev/null && iptables -t nat -L OUTPUT -n | grep -q "WARP_GOOGLE"; then
        echo -e "   iptables 拦截链: ${GREEN}✔ 正常挂载${RESET}"
    else
        echo -e "   iptables 拦截链: ${RED}✘ 未挂载 (直连模式)${RESET}"
    fi

    local http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://www.google.com" || echo "000")
    if [ "$http_status" -eq 200 ] || [ "$http_status" -eq 301 ] || [ "$http_status" -eq 302 ]; then
        echo -e "   连通性测试结果: ${GREEN}✔ 成功连接 (状态码: ${http_status})${RESET}"
        local total_time=$(curl -o /dev/null -s -w "%{time_total}" --max-time 5 "https://www.google.com")
        echo -e "   透明代理端延迟: ${YELLOW}${total_time} 秒${RESET}"
    else
        echo -e "   连通性测试结果: ${RED}✘ 失败 (状态码: ${http_status})${RESET}"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then proxy_status="${YELLOW}运行中 (接管 Google 流量)${RESET}"; fi
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}      Google 透明代理管理控制菜单       ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}1. 开启 Googl分流${RESET}"
        echo -e "${GREEN}2. 关闭 Google分流${RESET}"
        echo -e "${GREEN}3. 查看并验证代理连通性${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
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
#   模块二：Hev-Socks5-Tunnel 全局虚拟网卡三层控制中心 (Tun2Socks)
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

    # 自动加载本地现有的节点默认值
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

change_hev_config() {
    info "开始修改 Hev-Tunnel 节点配置："
    echo "--------------------------------------------------------"
    write_hev_config
    ok "核心节点配置文件渲染完毕！"
    if systemctl is-active --quiet "$HEV_SERVICE_NAME"; then
        step "正在自动重启隧道服务以生效..."
        systemctl restart "$HEV_SERVICE_NAME" && ok "配置已无缝重载生效。"
    fi
}

update_hev_core() {
    if [ ! -f "$HEV_BIN" ]; then
        error "尚未检测到 Tun2Socks 运行环境，请先执行选项 1 部署。"
        return 1
    fi
    step "正在接入 GitHub 检测 Hev 发行版快照（含多线路代理轮询）..."
    
    local latest_version=""
    local download_url=""
    
    # 采用多代理解析方案获取版本信息
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            # 针对不同反代源提取具体下载路径
            if [ -z "$proxy" ]; then
                download_url=$(echo "$release_json" | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
            else
                download_url="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            fi
            break
        fi
    done

    if [ -z "$latest_version" ] || [ -z "$download_url" ]; then
        error "未能获取到 GitHub 发行快照，底层网络握手超时。"
        return 1
    fi

    local local_version="未知"
    [ -f "$HEV_BIN" ] && local_version=$("$HEV_BIN" --version 2>&1 | grep "Version:" | awk '{print $2}')
    
    info "本地核心版本: ${local_version:-未知}"
    info "GitHub最新版: $latest_version"

    if [ "$local_version" = "$latest_version" ]; then
        ok "当前已经是最官方最新版本，无需重复升级。"
        return 0
    fi

    warn "检测到高版本演进，启动自动升级方案..."
    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak" was_immutable=false
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then chattr -i "$RESOLV_CONF" || true; was_immutable=true; fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    # 动态 DNS64 保护
    if ! set_dns64_servers "$RESOLV_CONF" "$was_immutable" "$RESOLV_CONF_BAK"; then return 1; fi

    local is_running=false
    if systemctl is-active --quiet "$HEV_SERVICE_NAME"; then is_running=true; systemctl stop "$HEV_SERVICE_NAME" || true; fi

    step "正在拉取最新编译核心文件..."
    local dl_success=0
    if curl -L -f -o "$HEV_BIN" "$download_url"; then
        dl_success=1
    else
        # 兜底：如果上面解析的代理下载失败，轮询整个代理池直接盲抓
        for proxy in "${GITHUB_PROXY[@]}"; do
            if curl -L -f -o "$HEV_BIN" "${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"; then
                dl_success=1; break
            fi
        done
    fi

    if [ "$dl_success" -eq 1 ]; then
        chmod +x "$HEV_BIN"
        ok "Hev-Tunnel 核心程序已成功演进至 $latest_version ！"
    else
        error "下载核心二进制受阻。"
    fi

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$was_immutable"
    if [ "$is_running" = true ]; then systemctl start "$HEV_SERVICE_NAME" && ok "全局控制总线重燃。"; fi
}

install_hev_tunnel() {
    cleanup_ip_rules
    if systemctl is-active --quiet "$HEV_SERVICE_NAME"; then systemctl stop "$HEV_SERVICE_NAME" || true; fi

    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak" WAS_IMMUTABLE=false
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then chattr -i "$RESOLV_CONF" || true; WAS_IMMUTABLE=true; fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    # 1. 动态 DNS64 机房自适应保护挂载
    if ! set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then return 1; fi

    step "正在获取 Hev-Socks5-Tunnel 最新 Release 标签..."
    local latest_version=""
    local DOWNLOAD_URL=""
    
    # 2. 核心引入：安装阶段应用主脚本的多代理解析逻辑
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            if [ -z "$proxy" ]; then
                DOWNLOAD_URL=$(echo "$release_json" | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
            else
                DOWNLOAD_URL="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            fi
            break
        fi
    done

    if [ -z "$latest_version" ] || [ -z "$DOWNLOAD_URL" ]; then
        error "未捕获到合规的核心下载链接，请检查网络或更换加速代理。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi

    step "正在通过代理通道下载 Hev 官方编译核心 (Version: $latest_version)..."
    cleanup_on_fail() { trap - INT TERM EXIT; restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"; return 1; }
    trap cleanup_on_fail INT TERM EXIT
    
    local dl_success=0
    if curl -L -f -o "$HEV_BIN" "$DOWNLOAD_URL"; then
        dl_success=1
    else
        # 3. 盲抓兜底机制：防止解析出的特定反代节点临时瘫痪
        for proxy in "${GITHUB_PROXY[@]}"; do
            if curl -L -f -o "$HEV_BIN" "${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"; then
                dl_success=1; break
            fi
        done
    fi
    trap - INT TERM EXIT

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    
    if [ "$dl_success" -ne 1 ]; then
        error "核心二进制下载完全失败，所有代理节点和直连均不可达。"
        return 1
    fi
    
    chmod +x "$HEV_BIN"

    step "初始化设置本地三层出口参数..."
    write_hev_config

    local WARP_PORT=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    [ -z "$WARP_PORT" ] && WARP_PORT="1080"

    local RULE_ADD_FROM_MAIN_IP="" RULE_DEL_FROM_MAIN_IP="" RULE_ADD_FROM_MAIN_IP6="" RULE_DEL_FROM_MAIN_IP6=""
    local MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

    if [ -n "$MAIN_IP" ]; then
        RULE_ADD_FROM_MAIN_IP="ExecStartPost=-/sbin/ip rule add from $MAIN_IP lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP="ExecStop=-/sbin/ip rule del from $MAIN_IP lookup main pref 15"
    fi
    if [ -n "$MAIN_IP6" ]; then
        RULE_ADD_FROM_MAIN_IP6="ExecStartPost=-/sbin/ip -6 rule add from $MAIN_IP6 lookup main pref 15"
        RULE_DEL_FROM_MAIN_IP6="ExecStop=-/sbin/ip -6 rule del from $MAIN_IP6 lookup main pref 15"
    fi

    cat > "$HEV_SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Hev Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$HEV_BIN $HEV_CONFIG_FILE
ExecStartPost=/bin/sleep 1
LimitNOFILE=524288

# 防断网策略：SSH直连
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 sport 22 lookup main pref 5

# 防回环策略：回环与目标端口通配直连
ExecStartPost=-/sbin/ip rule add to 127.0.0.1 lookup main pref 4
ExecStartPost=-/sbin/ip -6 rule add to ::1 lookup main pref 4
ExecStartPost=-/sbin/ip rule add to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4

ExecStartPost=-/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip route add default dev tun0 table 20
ExecStartPost=-/sbin/ip rule add lookup 20 pref 20
${RULE_ADD_FROM_MAIN_IP}
${RULE_ADD_FROM_MAIN_IP6}
ExecStartPost=-/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=-/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=-/sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 sport 22 lookup main pref 5

ExecStop=-/sbin/ip rule del to 127.0.0.1 lookup main pref 4
ExecStop=-/sbin/ip -6 rule del to ::1 lookup main pref 4
ExecStop=-/sbin/ip rule del to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4

ExecStop=-/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip route del default dev tun0 table 20
ExecStop=-/sbin/ip rule del lookup 20 pref 20
${RULE_DEL_FROM_MAIN_IP}
${RULE_DEL_FROM_MAIN_IP6}
ExecStop=-/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=-/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=-/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$HEV_SERVICE_NAME" 2>/dev/null
    step "正在自动拉起 Hev-Tunnel 三层全局托管路由网卡..."
    systemctl start "$HEV_SERVICE_NAME" && ok "Tun2Socks 环境配置完毕！已成功兼容本地节点。" || warn "隧道拉起失败，请检查服务状态。"
}
uninstall_hev_tunnel() {
    cleanup_ip_rules
    step "正在全盘收缴注销后台 Hev 守护进程文件..."
    if systemctl is-active --quiet "$HEV_SERVICE_NAME"; then systemctl stop "$HEV_SERVICE_NAME"; fi
    systemctl disable "$HEV_SERVICE_NAME" 2>/dev/null || true

    [ -f "$HEV_SERVICE_FILE" ] && rm -f "$HEV_SERVICE_FILE"
    [ -d "$HEV_CONFIG_DIR" ] && rm -rf "$HEV_CONFIG_DIR"
    [ -f "$HEV_BIN" ] && rm -f "$HEV_BIN"
    
    systemctl daemon-reload
    ok "Hev-Socks5-Tunnel 三层环境已从系统彻底清除。"
}

test_hev_exit_ip() {
    step "正在测试 Hev 三层网络虚拟网卡落地出口 IP..."
    local ip_info=""
    local test_urls=("https://api.ipify.org?format=json" "https://ipinfo.io/json" "https://ifconfig.me/all.json")

    for url in "${test_urls[@]}"; do
        info "正在请求探测接口: $url ..."
        ip_info=$(curl --noproxy "*" -s -m 6 "$url" 2>/dev/null || echo "")
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
        ok "双向连通验证通过！"
    else
        warn "出口 IP 捕获失败，建议在终端手动核验：curl https://myip.ipip.net"
    fi
}

menu_hev_tunnel_center() {
    while true; do
        clear
        local status_show="${RED}已停止 (未运行)${RESET}"
        [ -f "$HEV_BIN" ] && local version_raw=$("$HEV_BIN" --version 2>&1 | grep "Version:" | awk '{print $2}')
        local version_show="${YELLOW}${version_raw:-已安装}${RESET}"
        [ ! -f "$HEV_BIN" ] && version_show="${RED}未安装${RESET}"
        
        if systemctl is-active --quiet "$HEV_SERVICE_NAME"; then status_show="${GREEN}已启动 (三层全局托管中)${RESET}"; fi
        
        local port_show="${RED}无配置${RESET}"
        if [ -f "$HEV_CONFIG_FILE" ]; then
            local port=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
            local addr=$(grep -E '^[[:space:]]*address:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
            port_show="${YELLOW}${addr}:${port}${RESET}"
        fi

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
        
        read -p $'\e[35m请输入选项: \e[0m' num
        case "$num" in
            1) install_hev_tunnel ;;
            2) update_hev_core ;;
            3) uninstall_hev_tunnel ;;
            4) change_hev_config ;;
            5)
                step "激活全局网络托管状态..."
                if [ ! -f "$HEV_CONFIG_FILE" ]; then error "未发现有效节点配置信息。"; else systemctl start "$HEV_SERVICE_NAME" && ok "启动完毕。"; fi
                ;;
            6) step "归还物理网卡默认控制路由..." ; systemctl stop "$HEV_SERVICE_NAME" && ok "全局代理已彻底注销销毁。" ;;
            7) step "重新注入服务上下文..." ; systemctl restart "$HEV_SERVICE_NAME" && ok "重启完毕。" ;;
            8) step "拉取最新的30行核心运行日志:" ; echo "--------------------------------" ; journalctl -u "$HEV_SERVICE_NAME" -n 30 --no-pager ;;
            9) test_hev_exit_ip ;;
            0|*) return ;;
        esac
        echo -ne "${YELLOW}按任意键继续...${RESET}"
        read -r
    done
}

# --- 综合大联动彻底卸载函数 ---
fully_uninstall_all() {
    step "开始执行全盘综合大联动卸载机制..."
    
    # 临时关闭错误即退出(set -e)，确保即使某个服务没安装，卸载也能继续往下走
    set +e

    # 1. 停止并禁用所有相关系统服务
    info "正在停止后台守护进程..."
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    
    systemctl stop "$HEV_SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$HEV_SERVICE_NAME" >/dev/null 2>&1
    
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1

    # 2. 清理底层高级策略路由、iptables 和网络规则
    cleanup_ip_rules

    # 3. 强行删除所有二进制文件和 systemd 服务脚本
    info "正在移除系统二进制文件与服务描述符..."
    rm -f "$INSTALL_BIN" "$SERVICE_FILE" "$META_FILE" "$PROXY_SERVICE_FILE" "$REDSOCKS_CONF" "$PROXY_RULES_SCRIPT" "$HEV_BIN" "$HEV_SERVICE_FILE"

    # 4. 强行删除所有配置文件夹（安全检查：防止变量为空导致误删 / ）
    info "正在清理配置文件目录..."
    [ -n "$CONF_DIR" ] && [ "$CONF_DIR" != "/" ] && rm -rf "$CONF_DIR"
    [ -n "$DATA_DIR" ] && [ "$DATA_DIR" != "/" ] && rm -rf "$DATA_DIR"
    [ -n "$HEV_CONFIG_DIR" ] && [ "$HEV_CONFIG_DIR" != "/" ] && rm -rf "$HEV_CONFIG_DIR"

    # 5. 刷新 systemd 守护进程状态
    systemctl daemon-reload

    # 恢复错误即退出(set -e) 保证主脚本后续逻辑的严谨性
    set -e

    ok "已彻底将核心组件、Google透明代理及Hev-Tunnel(Tun2Socks)三层网卡组件全部清理干净。"
    sleep 1
}

# --- 主循环控制中心 ---
while true; do
    get_status_info; clear
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
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) download_bin; register_usque; write_systemd "SOCKS5" "127.0.0.1" "1080" "" ""; systemctl restart "$SERVICE_NAME"; ok "安装完成。"; sleep 0.5 ;;
        2) systemctl stop "$SERVICE_NAME"; download_bin; systemctl start "$SERVICE_NAME"; ok "更新完成。"; sleep 0.5 ;;
        3) fully_uninstall_all ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "服务已启动。"; sleep 0.5 ;; 
        6) systemctl stop "$SERVICE_NAME" && ok "服务已停止。"; sleep 0.5 ;;  
        7) systemctl restart "$SERVICE_NAME" && ok "服务已重启。"; sleep 0.5 ;; 
        8) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
        9) menu_show_node_config ;;
        10) menu_transparent_proxy_center ;;
        11) menu_hev_tunnel_center ;;
        0) exit 0 ;;
        *) warn "无效选项，请重新选择。" ;; 
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
