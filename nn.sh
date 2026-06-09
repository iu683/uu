#!/usr/bin/env bash
set -e

# ==============================================================================
#   Usque (MASQUE-WARP) 全能综合控制面板 (Alpine Linux 专属 OpenRC 精准优化版)
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
    if ! command -v ss >/dev/null 2>&1; then missing_deps="$missing_deps iproute2"; fi # Alpine 需要完整的 iproute2 才有 ss

    if [ -n "$missing_deps" ]; then
        warn "未检测到必要组件，正在尝试通过 apk 自动补齐: $missing_deps..."
        apk update -q && apk add -q unzip iproute2 curl bash iptables || die "组件缺失且自动安装失败，请手动执行 apk add 补齐。"
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

    # 强力清场，解决 Text file busy 报错
    killall -9 usque 2>/dev/null || true
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

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
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
    echo -e "${YELLOW}说明：直接回车保持不变，输入 clear 则清空该项${RESET}"
    
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
    elif [ "$i_user" = "clear" ]; then
        n_user=""
    else
        n_user="$i_user"
    fi

    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then
        n_pass="$o_pass"
    elif [ "$i_pass" = "clear" ]; then
        n_pass=""
    else
        n_pass="$i_pass"
    fi

    write_openrc_service "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" restart && ok "配置已更新并重启服务。"
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
        warn "验证失败，请检查端口、鉴权或 WARP 后台状态。"
    fi
}

# ==============================================================================
#   模块一：Google 透明代理专属控制中心 (Alpine Linux 专属定制)
# ==============================================================================
start_transparent_proxy() {
    if rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1; then
        warn "Google 透明分流代理已经处于运行状态，无需重复启动。"
        return
    fi

    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        warn "核心 WARP 核心服务未在后台运行！请先开启主服务。"
        return
    fi

    local warp_ip="127.0.0.1" warp_port="1080" has_auth=""
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r _ warp_ip warp_port has_auth _ < "$META_FILE"
    fi

    info "正在安装透明代理依赖组件 (redsocks / iptables)..."
    apk add -q redsocks iptables

    info "正在优化并黑洞 Google IPv6 路由解析..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true

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
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE
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

    # 写入 Alpine OpenRC init 服务
    cat <<EOF > "$PROXY_SERVICE_FILE"
#!/sbin/openrc-run

description="Cloudflare WARP Google Transparent Proxy (Redsocks Engine)"
supervisor="supervise-daemon"
command="/usr/sbin/redsocks"
command_args="-c ${REDSOCKS_CONF}"

start_post() {
    ${PROXY_RULES_SCRIPT} start
}

stop_pre() {
    ${PROXY_RULES_SCRIPT} stop
}
EOF
    chmod +x "$PROXY_SERVICE_FILE"
    rc-update add "$PROXY_SERVICE_NAME" default >/dev/null 2>&1
    rc-service "$PROXY_SERVICE_NAME" start
    
    sleep 1.5
    if rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1; then
        ok "Google 透明分流代理已成功挂载！"
    else
        warn "透明代理拉起失败。"
    fi
}

stop_transparent_proxy() {
    # 彻底清洗防火墙和杀死潜伏进程
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
    rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$PROXY_SERVICE_NAME" default >/dev/null 2>&1 || true
    killall -9 redsocks 2>/dev/null || true
    ok "Google 透明代理已彻底安全停止，劫持网链物理全盘卸载。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 透明代理链路深度验证 =========${RESET}"
    
    # 针对 Alpine 网络栈的防穿透精准断言
    if ! ss -lnpt | grep -q "12345"; then
        echo -e "   Redsocks 监听: ${RED}✘ 12345 端口未就绪 (服务未启动)${RESET}"
        echo -e "   连通性测试结果: ${RED}✘ 拦截终止 (当前系统已完全切换回直连模式)${RESET}"
        echo -e "${CYAN}========================================${RESET}"
        return
    fi

    if iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "WARP_GOOGLE"; then
        echo -e "   iptables 拦截链: ${GREEN}✔ 正常挂载${RESET}"
    else
        echo -e "   iptables 拦截链: ${RED}✘ 未挂载${RESET}"
    fi

    # 显式指定走 redsocks 本地劫持代理端口反向交叉核验
    local http_status=$(curl -o /dev/null -s -w "%{http_code}" --socks5-hostname 127.0.0.1:12345 --max-time 5 "https://www.google.com" || echo "000")
    if [ "$http_status" -eq 200 ]; then
        echo -e "   连通性测试结果: ${GREEN}✔ 成功经由 Redsocks 转发分流 (状态码: ${http_status})${RESET}"
        local total_time=$(curl -o /dev/null -s -w "%{time_total}" --socks5-hostname 127.0.0.1:12345 --max-time 5 "https://www.google.com")
        echo -e "   透明代理端延迟: ${YELLOW}${total_time} 秒${RESET}"
    else
        echo -e "   连通性测试结果: ${RED}✘ 失败 (状态码: ${http_status}，请确认后端 WARP 主程序是否工作)${RESET}"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1; then proxy_status="${YELLOW}运行中 (接管 Google 流量)${RESET}"; fi
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}    Google 透明代理管理控制菜单 (Alpine)  ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}1. 开启 Google 分流${RESET}"
        echo -e "${GREEN}2. 关闭 Google 分流${RESET}"
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
#   模块二：Hev-Socks5-Tunnel 全局虚拟网卡三层控制中心 (Alpine Linux 深度适配)
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

    read -r -p "请输入用户名 (保持留空回车，清空输入 none) [${current_user:-无}]: " input_user
    input_user="${input_user:-$current_user}"
    [ "$input_user" = "none" ] && input_user=""

    local input_pass=""
    if [ -n "$input_user" ]; then
        read -r -p "请输入密码 (保持留空回车，清空输入 none) [${current_pass:-无}]: " input_pass
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
    if rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1; then
        step "正在自动重启隧道服务以生效..."
        rc-service "$HEV_SERVICE_NAME" restart && ok "配置已无缝重载生效。"
    fi
}

install_hev_tunnel() {
    cleanup_ip_rules
    
    # 彻底释放底层残留占用，杜绝 Text file busy 报错
    rc-service "$HEV_SERVICE_NAME" stop >/dev/null 2>&1 || true
    killall -9 tun2socks 2>/dev/null || true
    rm -f "$HEV_BIN"

    local RESOLV_CONF="/etc/resolv.conf" RESOLV_CONF_BAK="/etc/resolv.conf.bak" WAS_IMMUTABLE=false
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then chattr -i "$RESOLV_CONF" || true; WAS_IMMUTABLE=true; fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    if ! set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then return 1; fi

    step "正在检索 Tun2Socks 最新 Release 二进制..."
    local latest_version="" DOWNLOAD_URL=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        local release_json=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$HEV_REPO/releases/latest" 2>/dev/null)
        latest_version=$(echo "$release_json" | grep '"tag_name":' | cut -d '"' -f 4)
        if [ -n "$latest_version" ]; then
            DOWNLOAD_URL="${proxy}https://github.com/$HEV_REPO/releases/download/${latest_version}/hev-socks5-tunnel-linux-x86_64"
            break
        fi
    done

    if [ -z "$latest_version" ]; then
        error "未能获取核心下载链接。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi

    step "正在拉取 Hev 官方编译核心 (Version: $latest_version)..."
    curl -L -f -o "$HEV_BIN" "$DOWNLOAD_URL"
    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    chmod +x "$HEV_BIN"

    write_hev_config

    local WARP_PORT=$(grep -E '^[[:space:]]*port:' "$HEV_CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    [ -z "$WARP_PORT" ] && WARP_PORT="1080"

    # 精准拉取主程序的目标加密终点 IP，将其置顶为主路由免流，死锁克星
    local remote_endpoint=$(grep -o '"endpoint": *"[^"]*"' "$CONF_FILE" 2>/dev/null | awk -F '"' '{print $4}' | awk -F ':' '{print $1}')
    local RULE_BYPASS_CF=""
    if [ -n "$remote_endpoint" ]; then
        RULE_BYPASS_CF="/sbin/ip rule add to ${remote_endpoint} lookup main pref 3"
    fi

    # 写入 Alpine OpenRC 精准高级策略路由防回环 init 服务
    cat <<EOF > "$HEV_SERVICE_FILE"
#!/sbin/openrc-run

description="Tun2Socks Hev Tunnel Routing Service"
supervisor="supervise-daemon"
command="${HEV_BIN}"
command_args="${HEV_CONFIG_FILE}"

start_post() {
    /bin/sleep 1
    # SSH 直连豁免
    /sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
    /sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
    
    # 核心精准豁免
    ${RULE_BYPASS_CF}
    /sbin/ip rule add fwmark 438 lookup main pref 10
    /sbin/ip route add default dev tun0 table 20
    /sbin/ip rule add lookup 20 pref 20

    # 局域网内网豁免
    /sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
    /sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
    /sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
    /sbin/ip rule add to 192.168.0.0/16 lookup main pref 16
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
    rc-service "$HEV_SERVICE_NAME" start && ok "Tun2Socks 三层全局托管托管已成功启动！"
}

uninstall_hev_tunnel() {
    cleanup_ip_rules
    rc-service "$HEV_SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$HEV_SERVICE_NAME" default >/dev/null 2>&1 || true
    rm -f "$HEV_SERVICE_FILE" "$HEV_BIN"
    rm -rf "$HEV_CONFIG_DIR"
    ok "Tun2Socks 环境已从 Alpine 全盘抹除。"
}

test_hev_exit_ip() {
    step "正在测试三层虚拟网卡全局落地连通状态与出口 IP..."
    # 强制不使用任何普通代理环境变量，直接测试全局路由出网
    local ip_info=$(curl --noproxy "*" -s -m 8 "https://api.ipify.org?format=json" || echo "")
    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        echo -e " 落地真实出口数据: ${YELLOW}$ip_info${RESET}"
        echo -e "${GREEN}----------------------------------------${RESET}"
        ok "恭喜！三层全局网卡双向通路完全互通！"
    else
        warn "出口握手超时！请使用选项 6 查看系统日志追溯冲突。"
    fi
}

show_hev_logs() {
    echo -e "${CYAN}========= Tun2Socks 实时系统日志 (按 Ctrl+C 退出) =========${RESET}"
    # Alpine OpenRC 没有 journalctl，日志默认输出到 /var/log/messages
    if [ -f /var/log/messages ]; then
        grep "tun2socks" /var/log/messages | tail -n 30
        echo "--------------------------------------------------------"
        tail -f /var/log/messages | grep "tun2socks"
    else
        echo "未发现全局 syslog 日志存储文件。建议运行: apk add syslog-ng"
    fi
}

menu_hev_tunnel_center() {
    while true; do
        clear
        local status_show="${RED}已停止 (未运行)${RESET}"
        local version_show="${RED}未安装${RESET}"
        if [ -f "$HEV_BIN" ]; then version_show="${YELLOW}已安装${RESET}"; fi
        if rc-service "$HEV_SERVICE_NAME" status >/dev/null 2>&1; then status_show="${GREEN}已启动 (三层全局托管中)${RESET}"; fi
        
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}     Tun2Socks 全局代理管理面板 (Alpine)  ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $status_show"
        echo -e "${GREEN}核心版本 :${RESET} $version_show"
        echo -e "${GREEN}=====================================${RESET}"
        echo "1. 安装/重置 Tun2Socks 虚拟环境"
        echo "2. 卸载 Tun2Socks 虚拟网卡组件"
        echo "3. 修改对接分流节点配置"
        echo "5. 测试全局出口落地状态"
        echo "6. 查看 Tun2Socks 系统日志"
        echo "0. 返回主菜单"
        echo -e "${GREEN}=====================================${RESET}"
        read -r -p "请输入子选项: " sub_choice
        case "$sub_choice" in
            1) install_hev_tunnel ;;
            2) uninstall_hev_tunnel ;;
            3) change_hev_config ;;
            5) test_hev_exit_ip ;;
            6) show_hev_logs ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#   主业务面板逻辑控制网
# ==============================================================================
main_menu() {
    while true; do
        clear
        get_status_info
        echo -e "${CYAN}=====================================================${RESET}"
        echo -e "${CYAN}     Usque (MASQUE-WARP) 控制面板 [Alpine Linux 版]    ${RESET}"
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
        echo -e "  10. 进入 ${PURPLE}Google 透明分流代理控制台${RESET} (四层劫持)"
        echo -e "  11. 进入 ${PURPLE}Tun2Socks 全局虚拟网卡托管台${RESET} (三层全局)"
        echo "  0. 退出脚本"
        echo -e "${CYAN}=====================================================${RESET}"
        read -r -p "请输入选项 [0-11]: " main_choice
        case "$main_choice" in
            1) download_bin && register_usque && write_openrc_service "SOCKS5" "127.0.0.1" "1080" "" "" && rc-service "$SERVICE_NAME" start ;;
            2) rc-service "$SERVICE_NAME" start && ok "服务已拉起。" ;;
            3) rc-service "$SERVICE_NAME" stop && ok "服务已停止。" ;;
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

# 执行依赖检测
check_deps
# 进入控制流
main_menu
