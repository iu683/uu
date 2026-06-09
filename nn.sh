#!/usr/bin/env sh
# ==============================================================================
#   CF-WARP & Tun2Socks 终极双层控制面板 (POSIX / Alpine 专属黄金重构版)
# ==============================================================================

# 预检：由于 Alpine 默认不带高级语法，必须先自动补齐 bash 并切过去
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        apk update -q && apk add -q bash
    fi
    exec bash "$0" "$@"
fi

set -e

# ==============================================================================
#   全局变量与常量定义
# ==============================================================================
export REPO_USQUE="Diniboy1123/usque"
export REPO_TUN2SOCKS="heiher/hev-socks5-tunnel"

export SERVICE_NAME="usque"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
export META_FILE="${CONF_DIR}/.panel_meta"

export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_SERVICE_FILE="/etc/init.d/${PROXY_SERVICE_NAME}"
export REDSOCKS_PID="/run/usque-google-proxy.pid"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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

# GITHUB 代理加速池
GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    ''
)

[[ "$EUID" -ne 0 ]] && echo -e "${RED}[错误]${RESET} 请使用 root 权限运行！" && exit 1

# --- 底层日志函数 ---
info() { echo -e "${BLUE}[信息]${RESET} $1"; }
success() { echo -e "${GREEN}[成功]${RESET} $1"; }
warning() { echo -e "${YELLOW}[警告]${RESET} $1"; }
error() { echo -e "${RED}[错误]${RESET} $1"; }
step() { echo -e "${PURPLE}[步骤]${RESET} $1"; }

# ==============================================================================
#   CF-WARP 核心逻辑
# ==============================================================================
get_status_info() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi
    
    if [ -f "$INSTALL_BIN" ]; then
        local ver
        ver=$("$INSTALL_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        panel_version="${YELLOW}v${ver:-已安装}${RESET}"
    else
        panel_version="${RED}未安装${RESET}"
    fi
    
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r m_mode m_ip m_port _ < "$META_FILE"
        panel_port="${YELLOW}${m_mode}://$m_ip:$m_port${RESET}"
    else
        panel_port="${RED}未配置${RESET}"
    fi
}

check_deps() {
    local missing=""
    ! command -v unzip >/dev/null 2>&1 && missing="$missing unzip"
    ! command -v curl >/dev/null 2>&1 && missing="$missing curl"
    ! command -v ip >/dev/null 2>&1 && missing="$missing iproute2"
    if [ -n "$missing" ]; then
        apk update -q && apk add -q $missing >/dev/null 2>&1
    fi
}

install_warp() {
    check_deps
    local is_upgrade=0
    local o_mode="SOCKS5" o_ip="127.0.0.1" o_port="1080" o_user="" o_pass=""
    
    if [ -f "$CONF_FILE" ] && [ -f "$INSTALL_BIN" ]; then
        is_upgrade=1
        echo -e "${BLUE}[信息]${RESET} 检测到已有配置，正在进行无损覆盖升级..."
        if [ -f "$META_FILE" ]; then
            IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"
        fi
    else
        echo -e "${BLUE}[信息]${RESET} 正在全新安装 Usque 核心组件..."
    fi
    
    local has_v4=0
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then
        has_v4=1
    fi

    local ARCH=$(uname -m)
    local TARGET="linux_amd64"
    [[ "$ARCH" == "aarch64" ]] && TARGET="linux_arm64"

    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO_USQUE}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done
    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"

    local tmp_dir=$(mktemp -d)
    if curl -fsSL -L -o "$tmp_dir/zip" "${GITHUB_PROXY[0]}https://github.com/${REPO_USQUE}/releases/download/${latest_tag}/usque_${pure_ver}_${TARGET}.zip"; then
        unzip -q -o "$tmp_dir/zip" -d "$tmp_dir"
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        cp -f "$tmp_dir/usque" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
    fi
    rm -rf "$tmp_dir"

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR"
    
    if [ "$is_upgrade" -eq 1 ]; then
        write_openrc "$o_mode" "$o_ip" "$o_port" "$o_user" "$o_pass"
        rc-service "$SERVICE_NAME" start
        echo -e "${GREEN}[成功]${RESET} 核心组件已成功无损升级至最新版！"
        return 0
    fi

    echo -e "${BLUE}[信息]${RESET} 正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        echo -e "${GREEN}[成功]${RESET} Cloudflare 本地注册成功。"
        
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            echo -e "${BLUE}[信息]${RESET} 检测到纯 IPv6 环境，正在自动修正配置文件..."
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            [ -z "$v6_ep" ] && v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
            echo -e "${GREEN}[成功]${RESET} IPv6 修正已完成 (Endpoint: $v6_ep)。"
        fi
        
        echo -e "\n--- 请配置初始化绑定参数 ---"
        echo -e "请选择运行模式:"
        echo -e "  1. SOCKS5 (默认)"
        echo -e "  2. HTTP"
        echo -ne "${GREEN}请输入选项 [默认: 1]: ${RESET}"
        read -r mode_ch
        local ins_mode="SOCKS5"
        [[ "$mode_ch" == "2" ]] && ins_mode="HTTP"

        echo -ne "${GREEN}请输入监听 IP [默认: 127.0.0.1]: ${RESET}"
        read -r ins_ip
        ins_ip="${ins_ip:-127.0.0.1}"

        echo -ne "${GREEN}请输入监听端口 [默认: 1080]: ${RESET}"
        read -r ins_port
        ins_port="${ins_port:-1080}"

        echo -ne "${GREEN}请输入代理用户名 (留空则无验证): ${RESET}"
        read -r ins_user
        local ins_pass=""
        if [ -n "$ins_user" ]; then
            echo -ne "${GREEN}请输入代理密码: ${RESET}"
            read -r ins_pass
        fi

        write_openrc "$ins_mode" "$ins_ip" "$ins_port" "$ins_user" "$ins_pass"
        rc-service "$SERVICE_NAME" start
        echo -e "${GREEN}[成功]${RESET} WARP 安装并启动成功！"
    else
        echo -e "${RED}[错误]${RESET} 注册失败。提示：请确保你的 VPS 已开启 IPv6 外部访问能力。"
        return 1
    fi
}

write_openrc() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"
    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u ${user} -w ${pass}"

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
description="Usque WARP Proxy Server"
supervisor="supervise-daemon"
command="${INSTALL_BIN}"
command_args="--config ${CONF_FILE} ${args}"
command_background="yes"
directory="${CONF_DIR}"
output_log="/var/log/usque.log"
error_log="/var/log/usque.err"
depend() { need net; after firewall; }
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

edit_config() {
    if [ ! -f "$META_FILE" ]; then echo -e "${RED}[错误]${RESET} 未发现配置记录"; return; fi
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"
    echo "--- 修改配置 ---"
    read -r -p "请选择模式 (1.SOCKS5 2.HTTP) [当前: $o_mode]: " m_ch
    local n_mode="$o_mode"
    [[ "$m_ch" == "1" ]] && n_mode="SOCKS5"
    [[ "$m_ch" == "2" ]] && n_mode="HTTP"
    read -r -p "监听 IP [当前: $o_ip]: " n_ip; n_ip="${n_ip:-$o_ip}"
    read -r -p "监听端口 [当前: $o_port]: " n_port; n_port="${n_port:-$o_port}"
    
    read -r -p "请输入用户名 [当前: ${o_user:-无}]: " n_user
    n_user="${n_user:-$o_user}"
    local n_pass="$o_pass"
    if [ -n "$n_user" ]; then
        read -r -p "请输入新密码: " n_pass
    else
        n_pass=""
    fi

    write_openrc "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" restart
}

show_status() {
    if [ ! -f "$META_FILE" ]; then echo -e "${RED}[错误]${RESET} 未配置过服务"; return; fi
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"
    echo -e "\n代理模式: $b_mode | 监听: $b_ip:$b_port"
    local p_url="socks5://"
    [[ "$b_mode" == "HTTP" ]] && p_url="http://"
    [[ "$b_ip" == "0.0.0.0" ]] && b_ip="127.0.0.1"
    if curl -sS --max-time 6 -x "${p_url}${b_ip}:${b_port}" "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp=on"; then
        success "WARP 网络出口完全正常！"
    else
        error "代理未成功通过 WARP 出网，请检查日志。"
    fi
}

# ==============================================================================
#   谷歌分流二级菜单
# ==============================================================================
google_split_menu() {
    while true; do
        clear
        local g_status="${RED}未运行${RESET}"
        rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1 && g_status="${GREEN}运行中${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}        谷歌分流管理面板        ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $g_status"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}  1. 开启谷歌透明分流${RESET}"
        echo -e "${GREEN}  2. 关闭谷歌透明分流${RESET}"
        echo -e "${GREEN}  3. 验证谷歌分流连通性${RESET}"
        echo -e "${GREEN}  0. 返回主菜单${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r sub_ch
        case "$sub_ch" in
            1)
                if ! command -v redsocks &>/dev/null || ! command -v iptables &>/dev/null; then
                    echo -e "${BLUE}[信息]${RESET} 正在安装分流依赖组件..."
                    apk add -q redsocks iptables --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community/ || apk add -q redsocks iptables
                fi
                local REDSOCKS_BIN="/usr/bin/redsocks"
                [ ! -f "$REDSOCKS_BIN" ] && REDSOCKS_BIN=$(command -v redsocks 2>/dev/null || echo "/usr/sbin/redsocks")
                rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1 || true
                pkill -9 -f redsocks >/dev/null 2>&1 || true
                rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1 || true
                rm -f "$REDSOCKS_PID"
                ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
                IFS='|' read -r _ _ warp_port _ < "$META_FILE"
                cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port:-1080}; type = socks5; }
EOF
                [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
                cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="
8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12
35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20
66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14
108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16
173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19
"
if [ "$ACTION" = "start" ]; then
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345; done
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
fi
EOF
                chmod +x "$PROXY_RULES_SCRIPT"
                cat <<EOF > "$PROXY_SERVICE_FILE"
#!/sbin/openrc-run
supervisor="supervise-daemon"
command="${REDSOCKS_BIN}"
command_args="-c ${REDSOCKS_CONF}"
command_background="yes"
pidfile="${REDSOCKS_PID}"
start_post() { ${PROXY_RULES_SCRIPT} start; }
stop_pre() { ${PROXY_RULES_SCRIPT} stop; }
EOF
                chmod +x "$PROXY_SERVICE_FILE"
                rc-service "$PROXY_SERVICE_NAME" start
                success "谷歌分流规则已挂载完成！"
                ;;
            2)
                rc-service "$PROXY_SERVICE_NAME" stop 2>/dev/null || true
                pkill -9 -f redsocks >/dev/null 2>&1 || true
                rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1 || true
                rm -f "$REDSOCKS_PID"
                success "谷歌分流规则已卸载。"
                ;;
            3)
                echo -e "\n[正在验证谷歌透明拦截链路...]"
                if iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "WARP_GOOGLE"; then
                    echo -e " iptables 劫持链: ${GREEN}✔ 正常挂载${RESET}"
                else
                    echo -e " iptables 劫持链: ${RED}✘ 未发现劫持规则 (直连中)${RESET}"
                fi
                local code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://www.google.com" || echo "000")
                if [ "$code" -eq 200 ] || [ "$code" -eq 301 ] || [ "$code" -eq 302 ]; then
                    echo -e " 谷歌直连测试  : ${GREEN}✔ 成功连通 (状态码: $code)${RESET}"
                else
                    echo -e " 谷歌直连测试  : ${RED}✘ 连接失败 (状态码: $code)${RESET}"
                fi
                ;;
            0) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# ==============================================================================
#   Tun2Socks 核心分流与全局代理逻辑 (完美融入选项 11)
# ==============================================================================
test_dns64_server() {
    local dns_server=$1
    step "正在测试DNS64服务器 $dns_server 的连通性..."
    if ping6 -c 3 -W 2 "$dns_server" &>/dev/null; then
        info "DNS64服务器 $dns_server 可达。"
        return 0
    else
        warning "DNS64服务器 $dns_server 不可达。"
        return 1
    fi
}

test_github_access() {
    step "正在测试GitHub访问..."
    if curl -s -I -m 10 https://github.com >/dev/null; then
        success "GitHub访问测试成功。"
        return 0
    else
        warning "GitHub访问测试失败。"
        return 1
    fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    local was_immutable=$3
    step "恢复原始 DNS 配置..."
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
        success "DNS 配置已恢复。"
        if [ "$was_immutable" = true ]; then
            info "重新锁定 /etc/resolv.conf..."
            chattr +i "$resolv_conf" || warning "无法重新锁定 /etc/resolv.conf。"
            success "锁定完成。"
        fi
    else
        warning "未找到 DNS 备份文件 ($resolv_conf_bak)，无法自动恢复。"
        if [ "$was_immutable" = true ]; then
             warning "尝试锁定当前的 /etc/resolv.conf..."
             chattr +i "$resolv_conf" || warning "无法锁定 /etc/resolv.conf。"
        fi
    fi
}

set_dns64_servers() {
    local resolv_conf=$1
    local was_immutable=$2
    local resolv_conf_bak=$3
    step "设置 DNS64 服务器（用于无缝下载核心程序）..."
    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    if test_github_access; then return 0; fi
    warning "主DNS64服务器访问GitHub失败，尝试备选DNS64服务器..."
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            step "使用备选DNS64服务器: $dns_server"
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then
                success "使用备选DNS64服务器 $dns_server 成功访问GitHub。"
                return 0
            fi
        fi
    done
    error "所有DNS64服务器测试失败，无法访问GitHub。"
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    return 1
}

cleanup_ip_rules() {
    step "正在强行清理底层残留的 IP 规则和旧路由..."
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
    ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null || true
    ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null || true
    ip -6 rule del to ::/0 dport 22 lookup main pref 5 2>/dev/null || true
    ip -6 rule del to ::/0 sport 22 lookup main pref 5 2>/dev/null || true
    ip rule del to 127.0.0.1 lookup main pref 4 2>/dev/null || true
    ip -6 rule del to ::1 lookup main pref 4 2>/dev/null || true
    
    local cfg="/etc/tun2socks/config.yaml"
    if [ -f "$cfg" ]; then
        local p=$(grep -E '^[[:space:]]*port:' "$cfg" | head -n1 | awk '{print $2}' | tr -d "'\"")
        [ -n "$p" ] && ip rule del to 127.0.0.1 dport "$p" lookup main pref 4 2>/dev/null || true
    fi
    while ip rule del pref 15 2>/dev/null; do true; done
    while ip -6 rule del pref 15 2>/dev/null; do true; done
    while ip rule del pref 5 2>/dev/null; do true; done
    while ip -6 rule del pref 5 2>/dev/null; do true; done
    success "IP 基础路由规则全面洗净。"
}

download_with_proxy() {
    local target_path=$1
    local raw_url=$2
    local success_flag=1
    for proxy in "${GITHUB_PROXY[@]}"; do
        local final_url="${proxy}${raw_url}"
        if [ -z "$proxy" ]; then
            info "正在尝试通过 [ 原生直连 ] 下载..."
        else
            info "正在尝试通过加速代理 [ ${proxy} ] 下载..."
        fi
        if curl -L -m 45 -f -o "$target_path" "$final_url"; then
            success "文件下载成功！"
            success_flag=0
            break
        else
            warning "当前下载通道失败，正在尝试下一个..."
            [ -f "$target_path" ] && rm -f "$target_path"
        fi
    done
    return $success_flag
}

write_tun2socks_config() {
    local CONFIG_FILE="/etc/tun2socks/config.yaml"
    mkdir -p "/etc/tun2socks"
    local current_addr="" current_port="" current_user="" current_pass=""
    if [ -f "$CONFIG_FILE" ]; then
        current_addr=$(grep -E '^[[:space:]]*address:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_port=$(grep -E '^[[:space:]]*port:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_user=$(grep -E '^[[:space:]]*username:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
        current_pass=$(grep -E '^[[:space:]]*password:' "$CONFIG_FILE" | head -n1 | awk '{print $2}' | tr -d "'\"")
    fi

    local input_addr
    while true; do
        if [ -n "$current_addr" ]; then
            echo -ne "${GREEN}请输入Socks5服务器地址 [$current_addr]: ${RESET}"
            read -r input_addr
            [ -z "$input_addr" ] && input_addr=$current_addr
        else
            echo -ne "${GREEN}请输入Socks5服务器地址 (本地 WARP 请输 127.0.0.1): ${RESET}"
            read -r input_addr
        fi
        if [ -n "$input_addr" ]; then break; else error "服务器地址不能为空。"; fi
    done

    local input_port
    while true; do
        if [ -n "$current_port" ]; then
            echo -ne "${GREEN}请输入Socks5服务器端口 [$current_port]: ${RESET}"
            read -r input_port
            [ -z "$input_port" ] && input_port=$current_port
        else
            echo -ne "${GREEN}请输入Socks5服务器端口 (WARP 默认通常为 40000 或 1080): ${RESET}"
            read -r input_port
        fi
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。"
        fi
    done

    local input_user
    if [ -n "$current_user" ]; then
        echo -ne "${GREEN}请输入用户名 (回车保持现状, 彻底清空请输入 none) [$current_user]: ${RESET}"
        read -r input_user
        [ -z "$input_user" ] && input_user=$current_user
        [ "$input_user" = "none" ] && input_user=""
    else
        echo -ne "${GREEN}请输入用户名 (WARP无需验证直接留空回车): ${RESET}"
        read -r input_user
    fi

    local input_pass
    if [ -n "$input_user" ]; then
        if [ -n "$current_pass" ]; then
            echo -ne "${GREEN}请输入密码 (回车保持现状, 彻底清空请输入 none) [$current_pass]: ${RESET}"
            read -r input_pass
            [ -z "$input_pass" ] && input_pass=$current_pass
            [ "$input_pass" = "none" ] && input_pass=""
        else
            echo -ne "${GREEN}请输入密码 (可选，无验证直接留空回车): ${RESET}"
            read -r input_pass
        fi
    else
        input_pass=""
    fi

    input_addr=$(echo "$input_addr" | tr -d '\r' | sed "s/'/''/g")
    input_port=$(echo "$input_port" | tr -d '\r')
    input_user=$(echo "$input_user" | tr -d '\r' | sed "s/'/''/g")
    input_pass=$(echo "$input_pass" | tr -d '\r' | sed "s/'/''/g")

    cat > "$CONFIG_FILE" <<EOF
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

change_tun2socks_config() {
    info "开始修改 Socks5 节点配置（直接回车则保持现状不变）："
    echo "--------------------------------------------------------"
    write_tun2socks_config
    success "节点配置文件更新成功！"
    if rc-service tun2socks status 2>/dev/null | grep -q "started"; then
        step "检测到服务正在后台运行，正在自动重启以应用新配置..."
        rc-service tun2socks restart && success "重启成功，新节点配置已生效。" || error "重启失败，请检查服务状态。"
    fi
}

update_tun2socks_core() {
    if [ ! -f "/usr/local/bin/tun2socks" ]; then
        error "检测到您尚未安装 Tun2Socks 环境，请先使用选项 1 进行初始化安装！"
        return 1
    fi
    step "正在连接 GitHub 检查最新 Release Version..."
    local latest_release_json=$(curl -s https://api.github.com/repos/$REPO_TUN2SOCKS/releases/latest)
    local latest_version=$(echo "$latest_release_json" | grep '"tag_name":' | cut -d '"' -f 4)
    local download_url=$(echo "$latest_release_json" | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$latest_version" ] || [ -z "$download_url" ]; then
        error "无法从 GitHub 获取版本信息，网络可能受到干扰。"
        return 1
    fi
    local local_version="未知"
    if [ -f "/usr/local/bin/tun2socks" ]; then
        local_version=$(/usr/local/bin/tun2socks --version 2>&1 | grep "Version:" | awk '{print $2}')
        [ -z "$local_version" ] && local_version="未知"
    fi
    info "本地核心版本: $local_version"
    info "GitHub最新版本: $latest_version"

    if [ "$local_version" = "$latest_version" ]; then
        success "当前核心程序已是官方最新发布版，无需重复升级。"
        return 0
    fi
    warning "检测到新版本核心程序 ($latest_version)，开始全自动无缝升级..."

    local RESOLV_CONF="/etc/resolv.conf"
    local RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    local was_immutable=false
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        chattr -i "$RESOLV_CONF" || true
        was_immutable=true
    fi
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true
    if ! set_dns64_servers "$RESOLV_CONF" "$was_immutable" "$RESOLV_CONF_BAK"; then return 1; fi

    local is_running=false
    if rc-service tun2socks status 2>/dev/null | grep -q "started"; then
        is_running=true
        step "正在暂停全局代理以准备替换核心二进制..."
        rc-service tun2socks stop || true
    fi

    step "正在下载官方最新编译核心..."
    if ! download_with_proxy "/usr/local/bin/tun2socks" "$download_url"; then
        error "所有下载通道均失败，请检查网络。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$was_immutable"
        return 1
    fi
    chmod +x "/usr/local/bin/tun2socks"
    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$was_immutable"

    if [ "$is_running" = true ]; then
        step "正在恢复并重新启动全局代理..."
        rc-service tun2socks start && success "隧道已成功恢复运行！" || error "重启失败。"
    fi
}

generate_openrc_script() {
    local SERVICE_FILE="/etc/init.d/tun2socks"
    local TARGET_CONFIG="/etc/tun2socks/config.yaml"
    local WARP_PORT=$(grep -E '^[[:space:]]*port:' "$TARGET_CONFIG" | head -n1 | awk '{print $2}' | tr -d "'\"")
    [ -z "$WARP_PORT" ] && WARP_PORT="1080"
    local MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
    local MAIN_IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -oE 'src [a-fA-F0-9:]+' | awk '{print $2}')

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
description="Tun2Socks Tunnel Service adapted for CF WARP on Alpine"
supervisor="supervise-daemon"
command="/usr/local/bin/tun2socks"
command_args="/etc/tun2socks/config.yaml"
output_log="/var/log/tun2socks.log"
error_log="/var/log/tun2socks.err"
depend() { need net; after firewall; }
start_post() {
    ulimit -n 524288
    ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
    ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
    ip -6 rule add to ::/0 dport 22 lookup main pref 5
    ip -6 rule add to ::/0 sport 22 lookup main pref 5
    ip rule add to 127.0.0.1 lookup main pref 4
    ip -6 rule add to ::1 lookup main pref 4
    ip rule add to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4
    ip rule add fwmark 438 lookup main pref 10
    ip -6 rule add fwmark 438 lookup main pref 10
    ip route add default dev tun0 table 20
    ip rule add lookup 20 pref 20
    [ -n "${MAIN_IP}" ] && ip rule add from ${MAIN_IP} lookup main pref 15
    [ -n "${MAIN_IP6}" ] && ip -6 rule add from ${MAIN_IP6} lookup main pref 15
    ip rule add to 127.0.0.0/8 lookup main pref 16
    ip rule add to 10.0.0.0/8 lookup main pref 16
    ip rule add to 172.16.0.0/12 lookup main pref 16
    ip rule add to 192.168.0.0/16 lookup main pref 16
    return 0
}
stop_post() {
    ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5 2>/dev/null
    ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5 2>/dev/null
    ip -6 rule del to ::/0 dport 22 lookup main pref 5 2>/dev/null
    ip -6 rule del to ::/0 sport 22 lookup main pref 5 2>/dev/null
    ip rule del to 127.0.0.1 lookup main pref 4 2>/dev/null
    ip -6 rule del to ::1 lookup main pref 4 2>/dev/null
    ip rule del to 127.0.0.1 dport ${WARP_PORT} lookup main pref 4 2>/dev/null
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null
    ip route del default dev tun0 table 20 2>/dev/null
    ip rule del lookup 20 pref 20 2>/dev/null
    [ -n "${MAIN_IP}" ] && ip rule del from ${MAIN_IP} lookup main pref 15 2>/dev/null
    [ -n "${MAIN_IP6}" ] && ip -6 rule del from ${MAIN_IP6} lookup main pref 15 2>/dev/null
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null
    return 0
}
EOF
    chmod +x "$SERVICE_FILE"
}

install_tun2socks() {
    cleanup_ip_rules
    step "检查 tun2socks 服务当前状态..."
    if rc-service tun2socks status 2>/dev/null | grep -q "started"; then
        info "检测到 tun2socks 旧进程正在运行，正在将其安全终止..."
        rc-service tun2socks stop || true
    fi

    local RESOLV_CONF="/etc/resolv.conf"
    local RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    local WAS_IMMUTABLE=false

    step "检查 /etc/resolv.conf 文件属性状态..."
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        info "/etc/resolv.conf 文件当前被系统锁定，正在临时解除..."
        chattr -i "$RESOLV_CONF" || { error "临时解锁 /etc/resolv.conf 失败"; exit 1; }
        WAS_IMMUTABLE=true
    fi

    step "备份系统当前 DNS 配置..."
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true
    if ! set_dns64_servers "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then return 1; fi

    local BINARY_PATH="/usr/local/bin/tun2socks"
    step "从 GitHub 获取最新 Release 核心下载地址..."
    local DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO_TUN2SOCKS/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        error "未找到适用于 linux-x86_64 的核心下载链接，请检查 network。"
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi

    step "正在通过代理池下载 GitHub 最新核心程序..."
    cleanup_on_fail() {
        trap - INT TERM EXIT
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    }
    trap cleanup_on_fail INT TERM EXIT
    
    if ! download_with_proxy "$BINARY_PATH" "$DOWNLOAD_URL"; then
        error "所有代理通道下载失败。"
        trap - INT TERM EXIT
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        return 1
    fi
    trap - INT TERM EXIT

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    chmod +x "$BINARY_PATH"

    step "正在初始化全局出口节点配置信息："
    write_tun2socks_config
    step "正在动态计算并生成 Alpine 守护服务 (OpenRC)..."
    generate_openrc_script
    rc-update add tun2socks default 2>/dev/null
    
    step "正在自动拉起全局 network 代理隧道..."
    rc-service tun2socks start && success "Tun2Socks 环境配置完毕！" || {
        error "自动启动隧道服务失败！请查看 /var/log/tun2socks.err 排查原因。"
        return 1
    }
}

uninstall_tun2socks() {
    cleanup_ip_rules
    step "正在停止并彻底禁用后台 OpenRC tun2socks 服务..."
    if rc-service tun2socks status 2>/dev/null | grep -q "started"; then
        rc-service tun2socks stop
    fi
    rc-update del tun2socks default 2>/dev/null || true
    step "正在清理系统残留组件文件..."
    rm -f "/etc/init.d/tun2socks" "/usr/local/bin/tun2socks"
    rm -rf "/etc/tun2socks"
    success "Tun2Socks 环境已彻底从系统卸载干净。"
}

get_tun2socks_status() {
    if rc-service tun2socks status 2>/dev/null | grep -q "started"; then
        t_status_show="${GREEN}已启动 (运行中)${RESET}"
    else
        t_status_show="${RED}已停止 (未运行)${RESET}"
    fi

    if [ -f "/usr/local/bin/tun2socks" ]; then
        local v_raw=$(/usr/local/bin/tun2socks --version 2>&1 | grep "Version:" | awk '{print $2}')
        t_version_show="${YELLOW}v${v_raw:-已安装}${RESET}"
    else
        t_version_show="${RED}未安装${RESET}"
    fi

    if [ -f "/etc/tun2socks/config.yaml" ]; then
        local port=$(grep -E '^[[:space:]]*port:' /etc/tun2socks/config.yaml | head -n1 | awk '{print $2}' | tr -d "'\"")
        local addr=$(grep -E '^[[:space:]]*address:' /etc/tun2socks/config.yaml | head -n1 | awk '{print $2}' | tr -d "'\"")
        t_port_show="${YELLOW}${addr}:${port}${RESET}"
    else
        t_port_show="${RED}无配置${RESET}"
    fi
}

test_exit_ip() {
    step "正在通过全局代理隧道查询落地出口 IP..."
    local ip_info=""
    local test_urls=("https://api.ipify.org?format=json" "https://ipinfo.io/json" "https://ifconfig.me/all.json")
    for url in "${test_urls[@]}"; do
        info "正在尝试请求: $url ..."
        ip_info=$(curl --noproxy "*" -s -m 6 "$url" 2>/dev/null || echo "")
        [ -n "$ip_info" ] && break
    done

    if [ -n "$ip_info" ]; then
        echo -e "${GREEN}----------------------------------------${RESET}"
        if echo "$ip_info" | grep -q "{"; then
            echo "$ip_info" | sed 's/["{}]//g' | sed 's/,/\n/g' | sed 's/^ *//'
        else
            echo -e "当前落地出口 IP: ${YELLOW}$ip_info${RESET}"
        fi
        echo -e "${GREEN}----------------------------------------${RESET}"
        success "测试成功！隧道网络双向畅通。"
    else
        error "获取失败。请检查后台服务状态或运行日志。"
    fi
}

# --- Tun2Socks 融合版二级管理面板 ---
tun2socks_menu() {
    while true; do
        get_tun2socks_status
        clear
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}      Tun2Socks 管理面板       ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}状态 :${RESET} $t_status_show"
        echo -e "${GREEN}版本 :${RESET} $t_version_show"
        echo -e "${GREEN}代理 :${RESET} $t_port_show"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}  1. 安装 Tun2Socks${RESET}"
        echo -e "${GREEN}  2. 更新 Tun2Socks${RESET}"
        echo -e "${GREEN}  3. 卸载 Tun2Socks${RESET}"
        echo -e "${GREEN}  4. 修改配置${RESET}"
        echo -e "${GREEN}  5. 启动 Tun2Socks${RESET}"
        echo -e "${GREEN}  6. 停止 Tun2Socks${RESET}"
        echo -e "${GREEN}  7. 重启 Tun2Socks${RESET}"
        echo -e "${GREEN}  8. 查看日志${RESET}"
        echo -e "${GREEN}  9. 测试当前出口IP${RESET}"
        echo -e "${GREEN}  0. 返回主菜单${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r num
        case "$num" in
            1) install_tun2socks ;;
            2) update_tun2socks_core ;;
            3) uninstall_tun2socks ;;
            4) change_tun2socks_config ;;
            5)
                step "正在唤醒全局代理网络..."
                if [ ! -f "/etc/tun2socks/config.yaml" ]; then
                    error "未发现任何节点配置，请先执行选项 1 或 4 进行配置！"
                else
                    rc-service tun2socks start && success "启动成功。" || error "启动失败。"
                fi
                ;;
            6)
                step "正在关闭全局代理，物理网络正在复原..."
                rc-service tun2socks stop && success "代理已停用，原网已恢复。" || error "停用失败。"
                ;;
            7)
                step "正在重启核心隧道服务..."
                rc-service tun2socks restart && success "重启成功。" || error "重启失败。"
                ;;
            8)
                step "正在查看服务运行日志尾部状态："
                echo "--------------------------------------------------------"
                if [ -f "/var/log/tun2socks.log" ]; then
                    tail -n 30 "/var/log/tun2socks.log"
                else
                    warning "未捕获到主标准日志，尝试读取错误日志："
                    [ -f "/var/log/tun2socks.err" ] && tail -n 30 "/var/log/tun2socks.err" || error "日志文件尚未生成。"
                fi
                ;;
            9) test_exit_ip ;;
            0) return ;;
            *) error "非法选项，请重新输入！" ;;
        esac
        echo -ne "${YELLOW}按任意键继续...${RESET}"
        read -r
    done
}

# ==============================================================================
#   主循环菜单
# ==============================================================================
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
    echo -e "${GREEN} 11.${RESET} ${CYAN}Tun2Socks全局代理${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    
    read -r choice
    
    case "$choice" in
        1) install_warp ;;
        2) install_warp ;; 
        3) 
            rc-service "$PROXY_SERVICE_NAME" stop 2>/dev/null || true
            pkill -9 -f redsocks >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
            rc-update del "$SERVICE_NAME" default 2>/dev/null || true
            rm -f "$SERVICE_FILE" "$PROXY_SERVICE_FILE" "$INSTALL_BIN" "$META_FILE" "$REDSOCKS_PID"
            rm -rf "$CONF_DIR" "$DATA_DIR"
            success "WARP 卸载完成。"
            ;;
        4) edit_config ;;
        5) rc-service "$SERVICE_NAME" start ;;
        6) rc-service "$SERVICE_NAME" stop ;;
        7) rc-service "$SERVICE_NAME" restart ;;
        8)
            echo "--- 最近 20 行日志 ---"
            [ -f /var/log/usque.log ] && tail -n 20 /var/log/usque.log || echo "暂无普通日志"
            [ -f /var/log/usque.err ] && tail -n 20 /var/log/usque.err || echo "暂无错误日志"
            ;;
        9) show_status ;;
        10) google_split_menu ;;
        11) tun2socks_menu ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回面板..."
done
