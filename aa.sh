#!/usr/bin/env bash
set -e

# ==============================================================================
#   CF-WARP 一体化控制面板 [3区独立自治·5重GitHub镜像+纯v6环境深度清洗重定向版]
# ==============================================================================

# ── 【区域 1】Usque (MASQUE-WARP) 变量与空间 ──
export REPO_WARP="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export BIN_WARP="/usr/local/bin/usque"
export CONF_DIR_WARP="/etc/usque"
export CONF_FILE="/etc/usque/config.json"
export FILE_SERVICE_WARP="/etc/systemd/system/${SERVICE_NAME}.service"
export META_WARP="${CONF_DIR_WARP}/.panel_meta"

# ── 【区域 2】Tun2Socks (全局网卡模式) 变量与空间 ──
export REPO_TUN="heiher/hev-socks5-tunnel"
export SERVICE_TUN="tun2socks"
export CONF_DIR_TUN="/etc/tun2socks"
export CONF_FILE_TUN="${CONF_DIR_TUN}/config.yaml"
export FILE_SERVICE_TUN="/etc/systemd/system/${SERVICE_TUN}.service"
export BIN_TUN="/usr/local/bin/tun2socks"
export META_TUN="${CONF_DIR_TUN}/.panel_meta"

# ── 【区域 3】Google 透明代理专属变量与空间 ──
export PROXY_SERVICE_NAME="warp-google-proxy"
export REDSOCKS_CONF="/etc/redsocks-google.conf"
export DATA_DIR="/etc/warp-google"
export PROXY_RULES_SCRIPT="${DATA_DIR}/proxy_rules.sh"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"

# ── 统一绿黄配色方案 ──
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

ALTERNATE_DNS64_SERVERS=("2a01:4f8:c2c:123f::1" "2a00:1098:2b::1" "2a01:4f9:c010:3f02::1")

# ⚡ 5 重高质量 GitHub 反代加速镜像源
GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/' '')

info()    { echo -e "${GREEN}[信息]${RESET} $1"; }
ok()      { echo -e "${GREEN}[成功]${RESET} $1"; }
success() { echo -e "${GREEN}[成功]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[警告]${RESET} $1"; }
warning() { echo -e "${YELLOW}[警告]${RESET} $1"; }
error()   { echo -e "${RED}[错误]${RESET} $1"; }
step()    { echo -e "${GREEN}[步骤]${RESET} $1"; }
die()     { echo -e "${RED}[致命错误]${RESET} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then error "请使用 root 权限运行此脚本。" >&2; exit 1; fi

cleanup_on_exit() { [ -f /etc/resolv.conf.bak ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf 2>/dev/null || true; }
trap cleanup_on_exit EXIT

if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS="ubuntu"; fi

# ==============================================================================
#   【区域 1 核心自治函数】 - Usque (WARP) 管理
# ==============================================================================
fetch_warp_version_and_status() {
    if [ -f "$META_WARP" ]; then
        local current_bind=$(grep -i 'bind' "$META_WARP" | awk -F '=' '{print $2}' | tr -d '" ')
        local bind_ip="${current_bind%%:*}" local bind_port="${current_bind##*:}"
    else
        local bind_ip="127.0.0.1" local bind_port="1080"
    fi
    port_warp="${YELLOW}${bind_ip}:${bind_port}${RESET}"

    if [ -f "$BIN_WARP" ]; then
        local v_w=$("$BIN_WARP" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "")
        version_warp="${YELLOW}v${v_w:-已安装}${RESET}"
    else
        version_warp="${RED}未安装${RESET}"
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        local connect_ip="$bind_ip"
        [ "$connect_ip" = "0.0.0.0" ] && connect_ip="127.0.0.1"
        local trace_out=$(curl --socks5-hostname "${connect_ip}:${bind_port}" -sS --max-time 4 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || echo "")
        
        if [ -n "$trace_out" ]; then
            local out_ip=$(echo "$trace_out" | grep -i '^ip=' | cut -d= -f2)
            status_warp="运行中 (\033[1;32m✔ 隧道畅通${RESET} | 出口: ${YELLOW}${out_ip}${RESET})"
        else
            status_warp="运行中 (${RED}✘ 隧道断流/鉴权失败${RESET})"
        fi
    else
        status_warp="${RED}已停止${RESET}"
    fi
}

download_warp_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) error "暂不支持的系统架构: $ARCH" && exit 1 ;;
    esac

    step "正在通过加速通道检索 WARP 最新内核版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        local api_url="https://api.github.com/repos/${REPO_WARP}/releases/latest"
        [ -n "$proxy" ] && api_url="${proxy}${api_url}"
        latest_tag=$(curl -fsSL --max-time 6 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
        [ -n "$latest_tag" ] && { success "通过镜像 [${proxy:-直连}] 成功抓取版本"; break; }
    done
    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    local dl_ok=0
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="https://github.com/${REPO_WARP}/releases/download/${latest_tag}/${zip_name}"
        [ -n "$proxy" ] && url="${proxy}${url}"
        step "正在尝试从镜像下载 WARP 内核: ${proxy:-直连 GitHub}"
        if curl -fsSL -L --max-time 30 -o "$tmp_dir/$zip_name" "$url"; then dl_ok=1; break; fi
    done

    if [ "$dl_ok" -eq 1 ] && [ -f "$tmp_dir/$zip_name" ]; then
        unzip -q -o "$tmp_dir/$zip_name" -d "$tmp_dir"
        if [ -f "$tmp_dir/usque" ]; then
            mkdir -p "$CONF_DIR_WARP"
            cp -f "$tmp_dir/usque" "$BIN_WARP"
            chmod +x "$BIN_WARP"
            success "Usque 内核部署完成。"
        else
            error "解压错误：未找到内核二进制文件。" && exit 1
        fi
    else
        error "所有加速镜像源均下载失败，请检查网络！" && exit 1
    fi
    rm -rf "$tmp_dir"
}

register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" 2>/dev/null; then has_v4=1; fi
    
    if [ "$has_v4" -ne 1 ]; then
        warn "检测到当前环境为纯 IPv6 环境，正在为您自动装载 DNS64 应急解析通道..."
        [ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf /etc/resolv.conf.bak || true
        echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
    fi

    mkdir -p "$CONF_DIR_WARP"
    cd "$CONF_DIR_WARP" || exit 1
    step "正在获取免交互 Team Token..."
    local jwt_token=$(curl -fsSL --max-time 15 "https://web--public--warp-team-api--coia-mfs4.code.run/" 2>/dev/null || echo "")
    
    local reg_cmd=("${BIN_WARP}" "register")
    if [[ "$jwt_token" =~ ^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        success "已拦截到有效的 Team 凭证"
        reg_cmd+=("--jwt" "${jwt_token}")
    fi

    if echo "y" | "${reg_cmd[@]}"; then
        success "Cloudflare 凭据注册完成。"
    else
        error "设备注册失败。" && exit 1
    fi

    if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
        info "正在对纯 IPv6 环境进行核心配置文件欺骗清洗..."
        if sed -i 's/"[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{2,5\}"/"[2606:4700:103::2]:2408"/g' "$CONF_FILE" 2>/dev/null; then
            ok "清洗成功：[endpoint_v4] 已重定向至 -> [2606:4700:103::2]:2408"
        else
            sed -i 's/"endpoint":.*/"endpoint": "[2606:4700:103::2]:2408",/g' "$CONF_FILE" 2>/dev/null || true
        fi
    fi

    [ -f /etc/resolv.conf.bak ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf || true
}

write_warp_systemd() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    local exec_args=("socks" "-b" "${bind_ip}" "-p" "${bind_port}")
    if [ -n "$username" ] && [ "$username" != "NONE" ] && [ -n "$password" ]; then exec_args+=("-u" "${username}" "-w" "${password}"); fi

    cat <<EOF > "$FILE_SERVICE_WARP"
[Unit]
Description=Cloudflare WARP MASQUE Proxy Client
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CONF_DIR_WARP}
ExecStart=${BIN_WARP} --config ${CONF_FILE} ${exec_args[@]}
Restart=always
RestartSec=4s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "bind=\"${bind_ip}:${bind_port}\"" > "$META_WARP"
    [ -n "$username" ] && [ "$username" != "NONE" ] && echo "username=\"${username}\"" >> "$META_WARP" || true
}

install_warp_core() {
    download_warp_bin
    register_usque
    info "拉起后台系统服务..."
    write_warp_systemd "127.0.0.1" "1080" "NONE" "NONE"
    systemctl restart "$SERVICE_NAME"
    sleep 1.5
    success "Usque 全自动部署成功！"
}

edit_warp_config() {
    local current_ip="127.0.0.1" local current_port="1080"
    if [ -f "$META_WARP" ]; then
        local current_bind=$(grep -i 'bind' "$META_WARP" | awk -F '=' '{print $2}' | tr -d '" ')
        current_ip="${current_bind%%:*}" current_port="${current_bind##*:}"
    fi
    echo ""
    read -r -p "请输入监听 IP 地址 [当前: ${current_ip}]: " input_ip
    local opt_ip="${input_ip:-$current_ip}"
    read -r -p "请输入 SOCKS5 监听端口 [当前: ${current_port}]: " input_port
    local opt_port="${input_port:-$current_port}"
    write_warp_systemd "$opt_ip" "$opt_port" "NONE" "NONE"
    systemctl restart "$SERVICE_NAME" && success "WARP 监听参数修改成功。"
}

# ==============================================================================
#   【区域 2 核心自治函数】 - Tun2Socks (全局网卡) 管理
# ==============================================================================
fetch_tun_version_and_status() {
    if systemctl is-active --quiet "$SERVICE_TUN"; then
        status_tun="运行中"
    else
        status_tun="${RED}已停止${RESET}"
    fi

    if [ -f "$BIN_TUN" ]; then
        local v_t=$("$BIN_TUN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "")
        version_tun="${YELLOW}v${v_t:-已安装}${RESET}"
    else
        version_tun="${RED}未安装${RESET}"
    fi

    if [ -f "$META_TUN" ]; then
        local target_bind=$(grep -i 'target_socks5' "$META_TUN" | awk -F '=' '{print $2}' | tr -d '" ')
        local has_auth=$(grep -i 'has_auth' "$META_TUN" | awk -F '=' '{print $2}' | tr -d '" ')
        if [ "$has_auth" = "true" ]; then
            port_tun="${YELLOW}${target_bind} (🔒 带认证)${RESET}"
        else
            port_tun="${YELLOW}${target_bind}${RESET}"
        fi
    elif [ -f "$CONF_FILE_TUN" ]; then
        local p_t=$(grep -E '^[[:space:]]*port:' "$CONF_FILE_TUN" | head -n1 | awk '{print $2}' | tr -d "'\"")
        local a_t=$(grep -E '^[[:space:]]*address:' "$CONF_FILE_TUN" | head -n1 | awk '{print $2}' | tr -d "'\"")
        port_tun="${YELLOW}${a_t}:${p_t}${RESET}"
    else
        port_tun="${RED}无目标配置${RESET}"
    fi
}

cleanup_ip_rules() {
    step "正在清洗全局网卡物理残留路由规则..."
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
}

install_tun2socks() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "检测到谷歌分流正在运行，正在将其安全关闭以防止路由冲突..."
        systemctl stop "$PROXY_SERVICE_NAME" || true
    fi

    cleanup_ip_rules
    mkdir -p "$CONF_DIR_TUN"
    
    if [ ! -f "$BIN_TUN" ]; then
        step "正在通过加速通道检索 Tun2Socks 最新版本数据..."
        local latest_tun_tag=""
        for proxy in "${GITHUB_PROXY[@]}"; do
            local api_url="https://api.github.com/repos/$REPO_TUN/releases/latest"
            [ -n "$proxy" ] && api_url="${proxy}${api_url}"
            latest_tun_tag=$(curl -fsSL --max-time 6 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
            [ -n "$latest_tun_tag" ] && break
        done
        [ -z "$latest_tun_tag" ] && latest_tun_tag="v2.5.2"

        local dl_ok=0
        for proxy in "${GITHUB_PROXY[@]}"; do
            local download_url="https://github.com/$REPO_TUN/releases/download/${latest_tun_tag}/tun2socks-linux-amd64.zip"
            [ -n "$proxy" ] && download_url="${proxy}${download_url}"
            step "正在尝试从镜像下载 Tun2Socks: ${proxy:-直连 GitHub}"
            
            local tmp_zip=$(mktemp -u).zip
            if curl -fsSL -L --max-time 30 -o "$tmp_zip" "$download_url"; then
                local tmp_unzip_dir=$(mktemp -d)
                if unzip -q -o "$tmp_zip" -d "$tmp_unzip_dir" 2>/dev/null; then
                    local found_bin=$(find "$tmp_unzip_dir" -type f -name "tun2socks*" | head -n1)
                    if [ -n "$found_bin" ]; then
                        cp -f "$found_bin" "$BIN_TUN"
                        chmod +x "$BIN_TUN"
                        dl_ok=1
                        rm -rf "$tmp_unzip_dir" "$tmp_zip"
                        break
                    fi
                fi
                rm -rf "$tmp_unzip_dir" "$tmp_zip"
            fi
        done

        if [ "$dl_ok" -ne 1 ]; then
            for proxy in "${GITHUB_PROXY[@]}"; do
                local raw_url="https://github.com/$REPO_TUN/releases/download/${latest_tun_tag}/tun2socks-linux-amd64"
                [ -n "$proxy" ] && raw_url="${proxy}${raw_url}"
                if curl -fsSL -L --max-time 30 -o "$BIN_TUN" "$raw_url"; then
                    chmod +x "$BIN_TUN" && dl_ok=1 && break
                fi
            done
        fi

        [ "$dl_ok" -eq 1 ] && success "Tun2Socks 核心程序部署成功！" || { error "Tun2Socks 镜像源悉数失联，下载失败。"; return; }
    fi

    local default_addr="127.0.0.1" local default_port="1080"
    if [ -f "$META_WARP" ]; then
        local current_bind=$(grep -i 'bind' "$META_WARP" | awk -F '=' '{print $2}' | tr -d '" ')
        default_addr="${current_bind%%:*}" default_port="${current_bind##*:}"
        [ "$default_addr" = "0.0.0.0" ] && default_addr="127.0.0.1"
    fi

    echo ""
    echo -e "${GREEN}>>> 全局托管网卡接入配置中心 <<<${RESET}"
    read -r -p "请输入目标 Socks5 代理 IP [回车默认使用本机WARP: $default_addr]: " custom_addr
    local final_addr="${custom_addr:-$default_addr}"
    read -r -p "请输入目标 Socks5 代理端口 [回车默认使用本机WARP: $default_port]: " custom_port
    local final_port="${custom_port:-$default_port}"

    local auth_yaml="" local has_auth="false"
    read -r -p "该 Socks5 代理是否需要账号密码认证？(y/N): " is_auth
    if [[ "$is_auth" =~ ^[Yy]$ ]]; then
        read -r -p "请输入 Socks5 用户名 (Username): " s_user
        read -r -p "请输入 Socks5 密码 (Password): " s_pass
        if [ -n "$s_user" ] && [ -n "$s_pass" ]; then
            auth_yaml="  username: '${s_user}'"$'\n'"  password: '${s_pass}'"
            has_auth="true"
        fi
    fi

    cat <<EOF > "$CONF_FILE_TUN"
tunnel:
  name: tun0
  mtu: 1500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $final_port
  address: '$final_addr'
$auth_yaml
  udp: 'udp'
  mark: 438
EOF

    echo "target_socks5=\"${final_addr}:${final_port}\"" > "$META_TUN"
    echo "has_auth=\"${has_auth}\"" >> "$META_TUN"

    local main_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local rule_v4_in="" local rule_v4_out=""
    [ -n "$main_ip" ] && rule_v4_in="ExecStartPost=-/sbin/ip rule add from $main_ip lookup main pref 15" && rule_v4_out="ExecStop=-/sbin/ip rule del from $main_ip lookup main pref 15"

    cat <<EOF > "$FILE_SERVICE_TUN"
[Unit]
Description=Tun2Socks Global Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_TUN $CONF_FILE_TUN
ExecStartPost=/bin/sleep 1

ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add to 127.0.0.1 lookup main pref 4
ExecStartPost=-/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip route add default dev tun0 table 20
ExecStartPost=-/sbin/ip rule add lookup 20 pref 20
${rule_v4_in}

ExecStop=-/sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 127.0.0.1 lookup main pref 4
ExecStop=-/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip route del default dev tun0 table 20
ExecStop=-/sbin/ip rule del lookup 20 pref 20
${rule_v4_out}

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks.service >/dev/null 2>&1
    systemctl restart tun2socks.service && success "Tun2Socks 全局网卡托管到 [${final_addr}:${final_port}] 并平稳启动！"
}

# ==============================================================================
#   【区域 3 核心自治函数】 - Google 透明代理分流管理
# ==============================================================================
fetch_google_version_and_status() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        local g_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 3 "https://www.google.com" || echo "000")
        if [ "$g_code" -eq 200 ] || [ "$g_code" -eq 301 ] || [ "$g_code" -eq 302 ]; then
            status_google="运行中 (\033[1;32m✔ Google 成功分流${RESET})"
        else
            status_google="运行中 (${RED}✘ 分流断流，响应码: ${g_code}${RESET})"
        fi
    else
        status_google="${RED}已停止${RESET}"
    fi

    if command -v redsocks &>/dev/null; then
        version_google="${YELLOW}已就绪 (Redsocks)${RESET}"
    else
        version_google="${RED}未就绪${RESET}"
    fi
}

start_transparent_proxy() {
    if systemctl is-active --quiet "$SERVICE_TUN"; then
        warn "检测到 Tun2Socks 全局网卡正在运行！请先去主菜单关闭全局网卡再开启专属分流。"
        return
    fi

    local current_bind="127.0.0.1:1080"
    if [ -f "$META_WARP" ]; then current_bind=$(grep -i 'bind' "$META_WARP" | awk -F '=' '{print $2}' | tr -d '" '); fi
    local warp_port="${current_bind##*:}"
    [ -z "$warp_port" ] && warp_port="1080"

    info "正在为您自动补齐透明代理依赖组件群 (redsocks / iptables)..."
    local proxy_missing=""
    if ! command -v redsocks &>/dev/null; then proxy_missing="$proxy_missing redsocks"; fi
    if ! command -v iptables &>/dev/null; then proxy_missing="$proxy_missing iptables"; fi

    if [ -n "$proxy_missing" ]; then
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y $proxy_missing >/dev/null 2>&1 ;;
            *) yum install -y redsocks iptables >/dev/null 2>&1 || true ;;
        esac
    fi

    systemctl stop redsocks >/dev/null 2>&1 || true
    systemctl disable redsocks >/dev/null 2>&1 || true

    cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port}; type = socks5; }
EOF

    mkdir -p "$DATA_DIR"
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
    systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl start "$PROXY_SERVICE_NAME" && ok "Google 专属透明分流代理已彻底启动成功！"
}

menu_transparent_proxy_center() {
    while true; do
        fetch_google_version_and_status
        clear
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "    【区域 3】 谷歌透明分流独立专属菜单      "
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 组件就绪 :${RESET} $version_google"
        echo -e "${GREEN} 分流状态 :${RESET} $status_google"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN} 1. 一键开启 谷歌专属透明分流代理${RESET}"
        echo -e "${GREEN} 2. 一键关闭 谷歌专属透明分流代理${RESET}"
        echo -e " ... "
        echo -e "${GREEN} 0. 返回大统一主菜单${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        read -r -p "请选择子区域操作: " sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) systemctl stop "$PROXY_SERVICE_NAME" && systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1 && ok "谷歌劫持链已完全御载。" ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p $'\n按任意键刷新本区...'
    done
}

# ==============================================================================
#   【大统一控制看盘】 - 全域数据拼装与总控循环
# ==============================================================================
uninstall_all() {
    cleanup_ip_rules
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE_TUN" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_TUN" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$BIN_WARP" "$FILE_SERVICE_WARP" "$BIN_TUN" "$FILE_SERVICE_TUN" "$PROXY_SERVICE_FILE" "$REDSOCKS_CONF" "$META_TUN"
    rm -rf "$CONF_DIR_WARP" "$CONF_DIR_TUN" "$DATA_DIR"
    systemctl daemon-reload
    success "全套三区域服务及本地元数据已完美清洗并全面还原。"
}

while true; do
    fetch_warp_version_and_status
    fetch_tun_version_and_status
    fetch_google_version_and_status

    clear
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "   CF-WARP 多区域独立自治控制台 (5路加速/纯v6清洗版)   "
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "${GREEN} [区域 1: WARP 内核]${RESET} 状态: $status_warp"
    echo -e "${GREEN}                     版本: $version_warp | 绑定: $port_warp"
    echo -e "${GREEN} [区域 2: 全局网卡]${RESET} 状态: $status_tun | 版本: $version_tun | 出口: $port_tun"
    echo -e "${GREEN} [区域 3: 谷歌分流]${RESET} 状态: $status_google"
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "${GREEN} 1. 安装 / 升级 WARP-Rust 服务端 (区 1 - 深度纯v6清洗优化)${RESET}"
    echo -e "${GREEN} 2. 修改 WARP-Rust 监听参数 (区 1)${RESET}"
    echo -e "${GREEN} 3. 重启 WARP-Rust 核心进程 (区 1)${RESET}"
    echo -e "---------------------------------------------------"
    echo -e "${GREEN} 4. 🚀 激活 Tun2Socks 全局托管网卡模式 (区 2 - 镜像下载/密码验证)${RESET}"
    echo -e "${GREEN} 5. 停用 Tun2Socks 全局托管网卡模式 (区 2)${RESET}"
    echo -e "---------------------------------------------------"
    echo -e "${GREEN} 6. 📂 进入谷歌透明代理专属管理菜单 (区 3)${RESET}"
    echo -e "---------------------------------------------------"
    echo -e "${GREEN} 7. 实时滚动查看 WARP 日志   8. 实时滚动查看 全局网卡日志${RESET}"
    echo -e "${YELLOW} 9. 彻底卸载清除全套三区域自治组件与残留元数据${RESET}"
    echo -e "${GREEN} 0. 安全退出当前管理面板${RESET}"
    echo -e "${GREEN}===================================================${RESET}"

    read -r -p "$(echo -e "${GREEN}请选择您要治理的区域功能序号: ${RESET}")" choice
    case "$choice" in
        1) install_warp_core ;;
        2) edit_warp_config ;;
        3) systemctl restart "$SERVICE_NAME" && success "WARP 核心重启指令下发完成。" ;;
        4) install_tun2socks ;;
        5) systemctl stop "$SERVICE_TUN" && cleanup_ip_rules && rm -f "$META_TUN" && success "全局网卡已下线，系统原生路由已复原。" ;;
        6) menu_transparent_proxy_center ;;
        7) (trap 'echo ""' INT; journalctl -u "$SERVICE_NAME" -n 30 -f) ;;
        8) (trap 'echo ""' INT; journalctl -u "$SERVICE_TUN" -n 30 -f) ;;
        9) uninstall_all ;;
        0) clear; exit 0 ;;
        *) warning "未知的选项，请重新选择！" && sleep 1 ;;
    esac

    echo ""
    echo -e "${YELLOW}按任意键返回多区主控制台...${RESET}"
    read -n 1 -s -r
done
