#!/bin/sh
# 针对 Alpine Linux 深度优化，使用标准 sh 执行
set -eu

# =========================================================
# Snell v6 + Shadow-TLS v3 独立管理脚本 (v6 独立命名版)
# =========================================================

# ================== 颜色与输出函数 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

_info() { echo -e "${GREEN}[信息] $1${RESET}"; }
_warn() { echo -e "${YELLOW}[警告] $1${RESET}"; }
_err()  { echo -e "${RED}[错误] $1${RESET}"; }

# ================== 基础变量 (全面注入 v6 独立命名空间) ==================
SNELL_DIR="/etc/snell-tls-v6"
SNELL_Conf="${SNELL_DIR}/snell-server-v6.conf"
SNELL_File="/usr/local/bin/snell-server-v6-hybrid"

STLS_Env="${SNELL_DIR}/shadow-tlsn-v6.env"
STLS_File="/usr/local/bin/stls-integrated-shadow-tlsn-v6"

LOG_FILE="/var/log/stls-integrated-snell-managers-v6.log"

# Snell v6 默认保底版本号
SNELL_DEFAULT_VERSION="6.0.0b3"

TMP_DIR=$(mktemp -d -t snell-v6-hybrid.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与暂停 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

pause() {
    echo -n "按任意键返回菜单..."
    read -r -n 1 -s || true
    echo
}

# ================== 智能获取公网双栈 IP ==================
get_public_ip() {
    local mode=${1:-"v4"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

# ================== 检查端口 ==================
check_port() {
    if netstat -tln | grep -q ":$1 "; then
        _err "端口 $1 已被占用"
        return 1
    fi
    return 0
}

# ================== 辅助生成器 ==================
random_key() {
    tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c 16 || echo "SnellPskKey12345"
}

random_port() {
    awk 'BEGIN{srand(); print int(rand()*(65000-2000+1))+2000}'
}

get_system_dns() { 
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//' || echo "1.1.1.1,8.8.8.8"
}

_map_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

detect_stls_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        *) _err "不支持架构: $(uname -m)" && exit 1 ;;
    esac
}

_get_snell_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
    if [ -n "$latest_version" ]; then
        echo "${latest_version#v}"
    else
        echo "$SNELL_DEFAULT_VERSION"
    fi
}

get_latest_stls_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 || echo "v0.2.25"
}

create_user() {
    # 先检查并创建组
    if ! getent group snell-tls-v6 >/dev/null 2>&1; then
        addgroup -S snell-tls-v6 >/dev/null 2>&1 || true
    fi
    # 再检查并创建用户，显式通过 -G 指定组
    if ! id -u snell-tls-v6 >/dev/null 2>&1; then
        adduser -S -D -H -s /sbin/nologin -G snell-tls-v6 snell-tls-v6 >/dev/null 2>&1 || true
    fi
}

# 精准无误的配置提取引擎 (兼容 BusyBox awk)
_get_conf_value() {
    local key="$1"
    if [ -f "$SNELL_Conf" ]; then
        grep -E "^${key}\s*=" "$SNELL_Conf" | awk -F'=' '{print $2}' | sed 's/ //g' | tr -d '\r\n'
    fi
}

# ================== 安全的数据提取引擎 ==================
load_existing_config() {
    OLD_STLS_PORT="8443"
    OLD_SNELL_PORT=""
    OLD_SNELL_PSK=""
    OLD_SNELL_MODE="default"
    OLD_STLS_PWD=""
    OLD_STLS_SNI="captive.apple.com"
    OLD_DNS=""
    OLD_TFO="true"
    OLD_DNS_PREF="default"

    if [ -f "$SNELL_Conf" ]; then
        local raw_listen=$(_get_conf_value "listen")
        if [ -n "$raw_listen" ]; then
            local first_listen="${raw_listen%%,*}"
            OLD_SNELL_PORT=$(echo "$first_listen" | awk -F: '{print $NF}')
        fi
        OLD_SNELL_PSK=$(_get_conf_value "psk")
        OLD_SNELL_MODE=$(_get_conf_value "mode")
        OLD_DNS=$(_get_conf_value "dns")
        OLD_TFO=$(_get_conf_value "tfo")
        OLD_DNS_PREF=$(_get_conf_value "dns-ip-preference")
    fi
    
    [ -z "$OLD_SNELL_MODE" ] && OLD_SNELL_MODE="default"

    if [ -f "$STLS_Env" ]; then
        OLD_STLS_PORT=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "443")
        OLD_STLS_PWD=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        
        local raw_tls
        raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        if [ -n "$raw_tls" ]; then
            OLD_STLS_SNI=${raw_tls%:[0-9]*}
        fi
        [ -z "$OLD_STLS_SNI" ] && OLD_STLS_SNI="captive.apple.com"
    fi
    return 0
}

# ================== 写配置核心引擎 ==================
write_config() {
    local snell_port="$1"
    local psk="$2"
    local snell_mode="$3"
    local dns="$4"
    local tfo="$5"
    local dns_pref="$6"
    local stls_port="$7"
    local stls_sni="$8"
    local stls_pwd="$9"

    mkdir -p "$SNELL_DIR"

    # Snell v6 特性升级：支持多模式选择、显式本地双栈桥接
    cat > "$SNELL_Conf" <<EOF
[snell-server]
listen = 127.0.0.1:$snell_port,[::1]:$snell_port
psk = $psk
mode = $snell_mode
obfs = off
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF
    chmod 600 "$SNELL_Conf"

    cat > "$STLS_Env" <<EOF
STLS_LISTEN=[::]:$stls_port
STLS_SERVER=127.0.0.1:$snell_port
STLS_TLS=$stls_sni:443
STLS_PASSWORD=$stls_pwd
EOF
    chmod 600 "$STLS_Env"

    create_user
    chown -R snell-tls-v6:snell-tls-v6 "$SNELL_DIR"
}

# ================== 生成并保存链接 ==================
generate_links() {
    local psk="$1"
    local snell_mode="$2"
    local tfo="$3"
    local stls_port="$4"
    local stls_sni="$5"
    local stls_pwd="$6"

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "server")

    cat > "${SNELL_DIR}/surge-v6.txt" <<EOF
$HOSTNAME-SnellV6+ShadowTLS = snell, $IP, $stls_port, psk=$psk, version=6, mode=$snell_mode, tfo=$tfo, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-version=3, reuse=true, ecn=true
EOF
    chown snell-tls-v6:snell-tls-v6 "${SNELL_DIR}/surge-v6.txt" || true
}

# ================== OpenRC 服务启动脚本构建 (带有 v6 独立后缀名) ==================
service() {
    create_user

    cat > /etc/init.d/snell-tlss-v6 <<'EOF'
#!/sbin/openrc-run

description="Snell v6 Server Service (Hybrid)"
command="/usr/local/bin/snell-server-v6-hybrid"
command_args="-c /etc/snell-tls-v6/snell-server-v6.conf"
command_background="yes"
command_user="snell-tls-v6:snell-tls-v6"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/snell-v6.log"
error_log="/var/log/snell-v6.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/snell-tlss-v6
    rc-update add snell-tlss-v6 default || true
    touch /var/log/snell-v6.log && chown snell-tls-v6:snell-tls-v6 /var/log/snell-v6.log || true
    rc-service snell-tlss-v6 start || true
}

service_stls() {
    cat > /etc/init.d/shadowtlsn-v6 <<'EOF'
#!/sbin/openrc-run

description="Shadow TLS Service v3 (Hybrid v6)"
command="/usr/local/bin/stls-integrated-shadow-tlsn-v6"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/shadowtls-v6.log"
error_log="/var/log/shadowtls-v6.log"

start_pre() {
    if [ -f /etc/snell-tls-v6/shadow-tlsn-v6.env ]; then
        . /etc/snell-tls-v6/shadow-tlsn-v6.env
    else
        eerror "Environment file /etc/snell-tls-v6/shadow-tlsn-v6.env missing!"
        return 1
    fi
    
    export MONOIO_FORCE_LEGACY_DRIVER=1
    command_args="--v3 server --password $STLS_PASSWORD --listen $STLS_LISTEN --server $STLS_SERVER --tls $STLS_TLS"
}

depend() {
    need net snell-tlss-v6
    after firewall snell-tlss-v6
}
EOF
    chmod +x /etc/init.d/shadowtlsn-v6
    rc-update add shadowtlsn-v6 default || true
    touch /var/log/shadowtls-v6.log && chown root:root /var/log/shadowtls-v6.log || true
    rc-service shadowtlsn-v6 start || true
    _info "OpenRC 专属自启服务部署配置完成！"
}

# ================== 打印配置详情 ==================
print_node_info() {
    IP=$(get_public_ip)
    if [ ! -f "$STLS_Env" ] || [ ! -f "$SNELL_Conf" ]; then
        _err "配置文件不存在，请先选择选项【1】进行安装初始化。" && return
    fi
    
    local snell_port
    local raw_listen=$(_get_conf_value "listen")
    local first_listen="${raw_listen%%,*}"
    snell_port=$(echo "$first_listen" | awk -F: '{print $NF}')
    local psk=$(_get_conf_value "psk")
    local snell_mode=$(_get_conf_value "mode")
    local dns_pref=$(_get_conf_value "dns-ip-preference")
    
    [ -z "$snell_mode" ] && snell_mode="default"
    local show_listen_port=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "未知")
    local stls_pwd=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "未知")
    
    local raw_tls b_sni="未知"
    raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
    if [ -n "$raw_tls" ]; then
        b_sni=${raw_tls%:[0-9]*}
    fi

    echo -e "${GREEN}====== Snell v6 + Shadow-TLS v3 配置 ======${RESET}"
    echo -e "${YELLOW} 入口公网 IP   : ${IP}${RESET}"
    echo -e "${YELLOW} 入口公网端口   : ${show_listen_port}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码: ${stls_pwd}${RESET}"
    echo -e "${YELLOW} SNI 伪装域名   : ${b_sni}${RESET}"
    echo -e "${YELLOW} 内部 Snell 端口 : ${snell_port} ${RESET}"
    echo -e "${YELLOW} Snell 工作模式 : ${snell_mode}${RESET}"
    echo -e "${YELLOW} Snell PSK 密钥 : ${psk}${RESET}"
    echo -e "${YELLOW} DNS 家族优先级 : ${dns_pref}${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    _info "Surge 6 专属托管节点配置:"
    if [ -f "${SNELL_DIR}/surge-v6.txt" ]; then
        echo -n -e "${YELLOW}"
        cat "${SNELL_DIR}/surge-v6.txt"
        echo -e "${RESET}"
    else
        echo "未生成配置"
    fi
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
}

# ================== 动态配置交互流 ==================
execute_configuration_flow() {
    local is_modify_mode="$1"
    
    load_existing_config || true
    
    local snell_port psk snell_mode dns tfo dns_pref stls_port stls_sni stls_pwd
    local input_stls_port input_snell_port input_psk input_mode input_stls_pwd input_sni input_dns input_tfo input_dns_pref

    while true; do
        printf "请输入 Shadow-TLS 入口公网端口 (当前/默认: %s): " "${OLD_STLS_PORT:-443}"
        read -r input_stls_port || input_stls_port=""
        stls_port=${input_stls_port:-${OLD_STLS_PORT:-443}}

        if echo "$stls_port" | grep -qE '^[0-9]+$' && [ "$stls_port" -ge 1 ] && [ "$stls_port" -le 65535 ]; then
            if [ "$stls_port" != "$OLD_STLS_PORT" ]; then
                check_port "$stls_port" || continue
            fi
            break
        else
            _err "端口格式不正确，必须在 1-65535 之间。"
        fi
    done

    while true; do
        local default_snell_port=""
        default_snell_port=${OLD_SNELL_PORT:-$(random_port || echo "38221")}
        
        printf "请输入内部本地 Snell 端口 (当前/随机: %s): " "$default_snell_port"
        read -r input_snell_port || input_snell_port=""
        snell_port=${input_snell_port:-$default_snell_port}

        if echo "$snell_port" | grep -qE '^[0-9]+$' && [ "$snell_port" -ge 1 ] && [ "$snell_port" -le 65535 ]; then
            if [ "$snell_port" -eq "$stls_port" ]; then
                _err "内部 Snell 端口绝不能与外网公共入口端口相同！"
                continue
            fi
            if [ "$snell_port" != "$OLD_SNELL_PORT" ]; then
                check_port "$snell_port" || continue
            fi
            break
        else
            _err "端口格式不正确，必须在 1-65535 之间。"
        fi
    done

    while true; do
        local default_psk=""
        default_psk=${OLD_SNELL_PSK:-$(random_key || echo "")}

        printf "请输入 Snell PSK 密钥 (当前/随机: %s):\n> " "$default_psk"
        read -r input_psk || input_psk=""
        psk=${input_psk:-$default_psk}
        if [ -n "$psk" ]; then break; else _err "PSK 密钥不能为空！"; fi
    done

    local default_mode="${OLD_SNELL_MODE:-default}"
    echo -e "\n${YELLOW}请选择 Snell v6 工作模式 (当前: $default_mode)：${RESET}"
    echo "1. default     (流量混淆 + AES 加密，全能传统模式)"
    echo "2. unshaped    (禁用内部混淆，纯加密传输，吞吐能效提升约 10%)"
    echo "3. unsafe-raw  (明文不加密模式：极度适合已套用外部 Shadow-TLS 保护的环境)"
    printf "请选择序号 (直接回车保持不变): "
    read -r input_mode || input_mode=""
    case $input_mode in
        1) snell_mode="default" ;;
        2) snell_mode="unshaped" ;;
        3) snell_mode="unsafe-raw" ;;
        *) snell_mode="$default_mode" ;;
    esac

    while true; do
        local default_stls_pwd=""
        default_stls_pwd=${OLD_STLS_PWD:-$(openssl rand -hex 8 2>/dev/null || echo "StlsPurePwd123456")}
        
        printf "请输入 Shadow-TLS 传输密码 (当前/随机: %s): " "$default_stls_pwd"
        read -r input_stls_pwd || input_stls_pwd=""
        stls_pwd=${input_stls_pwd:-$default_stls_pwd}
        if [ -n "$stls_pwd" ]; then break; else _err "密码不能为空！"; fi
    done

    while true; do
        local default_sni=${OLD_STLS_SNI:-"captive.apple.com"}
        printf "请输入 Shadow-TLS SNI 伪装域名 (当前/默认: %s): " "$default_sni"
        read -r input_sni || input_sni=""
        stls_sni=${input_sni:-$default_sni}
        if echo "$stls_sni" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            break
        else
            _err "伪装域名格式不正确，请输入合法的域名 (如 captive.apple.com)"
        fi
    done

    while true; do
        local sys_dns=""
        sys_dns=$(get_system_dns || echo "1.1.1.1,8.8.8.8")
        local default_dns=${OLD_DNS:-$sys_dns}
        
        printf "请输入 Snell 内部自定义 DNS (当前/默认: %s): " "$default_dns"
        read -r input_dns || input_dns=""
        dns=${input_dns:-$default_dns}
        if [ -n "$dns" ]; then break; else _err "DNS 不能为空！"; fi
    done

    local default_dns_pref="${OLD_DNS_PREF:-default}"
    echo -e "\n${YELLOW}请选择 Snell v6 DNS 解析 IP 家族优先级 (当前: $default_dns_pref)：${RESET}"
    echo "1. default      (系统默认)"
    echo "2. prefer-ipv4  (IPv4 优先)"
    echo "3. prefer-ipv6  (IPv6 优先)"
    echo "4. ipv4-only    (仅解析 IPv4)"
    echo "5. ipv6-only    (仅解析 IPv6)"
    printf "请选择序号 (直接回车保持不变): "
    read -r input_dns_pref || input_dns_pref=""
    case $input_dns_pref in
        1) dns_pref="default" ;;
        2) dns_pref="prefer-ipv4" ;;
        3) dns_pref="prefer-ipv6" ;;
        4) dns_pref="ipv4-only" ;;
        5) dns_pref="ipv6-only" ;;
        *) dns_pref="$default_dns_pref" ;;
    esac

    local default_tfo_str="开启"
    [ "$OLD_TFO" = "false" ] && default_tfo_str="关闭"
    printf "是否开启 TCP Fast Open？(当前: %s, 1.开启 2.关闭, 默认 1): " "$default_tfo_str"
    read -r input_tfo || input_tfo=""
    if [ "$input_tfo" = "1" ]; then tfo="true"; elif [ "$input_tfo" = "2" ]; then tfo="false"; else tfo="$OLD_TFO"; fi

    write_config "$snell_port" "$psk" "$snell_mode" "$dns" "$tfo" "$dns_pref" "$stls_port" "$stls_sni" "$stls_pwd" || true
    generate_links "$psk" "$snell_mode" "$tfo" "$stls_port" "$stls_sni" "$stls_pwd" || true
}

# ================== 核心 Alpine 部署与下载逻辑 ==================
_download_and_install_binary() {
    local sarch=$( _map_arch ) || { _err "不支持的架构"; return 1; }
    
    _info "正在安装 Alpine 必要系统依赖 (upx, unzip, curl, iproute2, openssl, shadow, gcompat)..."
    apk add --no-cache upx unzip curl iproute2 openssl shadow gcompat >/dev/null 2>&1

    _info "正在获取官方最新稳定版版本号..."
    local version=$( _get_snell_latest_version )
    version="${version#v}"

    local tmp=$(mktemp -d)
    local download_url_A="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"
    local download_url_B="https://dl.nssurge.com/snell/snell-server-${version}-linux-${sarch}.zip"
    local download_url_C="https://dl.nssurge.com/snell/snell-server-v6.0.0b3-linux-${sarch}.zip"

    _info "正在通过智能路由下载 Snell v6 核心组件..."
    
    if curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -o "$tmp/snell.zip" --connect-timeout 15 "$download_url_A" && unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
        _info "方案 A (标准新版 v${version}) 下载并校验成功！"
    elif curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "$tmp/snell.zip" --connect-timeout 15 "$download_url_B" && unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
        _info "方案 B (变体路径) 下载并校验成功！"
    else
        _warn "官方主动拦截或版本号未就绪，启动弹性回滚，下载 v6.0.0b3 保底包..."
        if ! curl -sL -A "Mozilla/5.0" -o "$tmp/snell.zip" --connect-timeout 20 "$download_url_C" || ! unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
            _err "所有下载源均被 Surge 防火墙拦截或网络超时，请稍后再试！"
            rm -rf "$tmp"; return 1
        fi
        version="6.0.0b3"
    fi

    if unzip -oq "$tmp/snell.zip" -d "$tmp/"; then
        _info "正在进行 UPX 壳解压兼容处理..."
        if command -v upx >/dev/null 2>&1; then
            upx -d "$tmp/snell-server" >/dev/null 2>&1 || _warn "UPX 脱壳失败或无需脱壳"
        else
            _err "UPX 工具不可用，无法完成解压"
            rm -rf "$tmp"; return 1
        fi

        install -m 755 "$tmp/snell-server" "$SNELL_File"
        rm -rf "$tmp"
        echo "$version" > "${SNELL_DIR}/version.txt"
        return 0
    else
        _err "解压失败"
        rm -rf "$tmp"
        return 1
    fi
}

# ================== 安装入口 ==================
install_ss() {
    _info "开始全新安装 Snell v6 & Shadow-TLS v3 核心组件..."
    mkdir -p "$SNELL_DIR"

    _download_and_install_binary

    STLS_VERSION=$(get_latest_stls_version)
    STLS_ARCH=$(detect_stls_arch)
    _info "正在下载 Shadow-TLS ${STLS_VERSION}..."
    wget -O "$TMP_DIR/shadow-tls" "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
    install -m 755 "$TMP_DIR/shadow-tls" "$STLS_File"
    echo "$STLS_VERSION" > "${SNELL_DIR}/stls_version.txt"

    execute_configuration_flow false
    service
    service_stls

    _info "服务安装部署成功，snellv6+Shadow-TLSv3 已启动运行！"
    log "全新安装并初始化成功"
    print_node_info
}

# ================== 修改现有配置 ==================
modify_ss() {
    _info "进入修改配置模块..."
    if [ ! -f "$SNELL_Conf" ] || [ ! -f "$STLS_Env" ]; then
        _err "错误：未检测到环境配置文件，请先选择选项【1】进行完整安装！"
        return
    fi
    
    _info "正在安全停止现有服务以防死锁..."
    rc-service shadowtlsn-v6 stop >/dev/null 2>&1 || true
    rc-service snell-tlss-v6 stop >/dev/null 2>&1 || true
    
    execute_configuration_flow true
    
    _info "正在通过 OpenRC 依赖链平滑安全启动服务..."
    rc-service snell-tlss-v6 start || true
    sleep 1 
    rc-service shadowtlsn-v6 start || true
    
    _info "核心配置已被覆写，服务安全重启完毕！"
    print_node_info
    log "配置已被修改并安全应用"
}

# ================== 更新 ==================
update_ss() {
    _info "开始更新二进制组件..."
    
    _info "正在安全停止旧服务..."
    rc-service shadowtlsn-v6 stop >/dev/null 2>&1 || true
    rc-service snell-tlss-v6 stop >/dev/null 2>&1 || true
    sleep 1

    if [ -f "$SNELL_Conf" ]; then
        _download_and_install_binary
    fi

    if [ -f "$STLS_Env" ]; then
        STLS_VERSION=$(get_latest_stls_version)
        STLS_ARCH=$(detect_stls_arch)
        wget -O "$TMP_DIR/shadow-tls" "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
        install -m 755 "$TMP_DIR/shadow-tls" "$STLS_File"
        echo "$STLS_VERSION" > "${SNELL_DIR}/stls_version.txt"
    fi

    _info "正在重新拉起全新组件..."
    rc-service snell-tlss-v6 start || true
    sleep 1
    rc-service shadowtlsn-v6 start || true
    
    _info "更新执行完毕，服务已安全重启"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    _warn "正在卸载 snellv6+Shadow-TLSv3 混合实例服务..."
    rc-service shadowtlsn-v6 stop || true
    rc-service snell-tlss-v6 stop || true
    rc-update del shadowtlsn-v6 default || true
    rc-update del snell-tlss-v6 default || true
    rm -f /etc/init.d/snell-tlss-v6 /etc/init.d/shadowtlsn-v6
    rm -rf "$SNELL_DIR"
    rm -f "$SNELL_File" "$STLS_File"
    _info "snellv6+Shadow-TLSv3 独立环境清理完毕"
    log "安全卸载成功"
}

# ================== 独立日志查看子菜单 ==================
check_logs() {
    while true; do
        clear
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}      Snell v6 + Shadow-TLS v3 日志面板      ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}1. 查看 Shadow-TLS v3 最新日志 (最后50行)${RESET}"
        echo -e "${YELLOW}2. 实时追踪 Shadow-TLS v3 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}-------------------------------------------${RESET}"
        echo -e "${YELLOW}3. 查看 Snell v6 最新日志 (最后50行)${RESET}"
        echo -e "${YELLOW}4. 实时追踪 Snell v6 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}===========================================${RESET}"
        echo -e "${RED}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        printf "\033[32m请选择日志操作: \033[0m"
        read -r log_choice || true
        
        case $log_choice in
            1)
                echo -e "\n${GREEN}====== Shadow-TLS v3 运行日志 ======${RESET}"
                if [ -f "/var/log/shadowtls-v6.log" ]; then tail -n 50 /var/log/shadowtls-v6.log; else _warn "暂无 Shadow-TLS v6 日志文件"; fi
                pause
                ;;
            2)
                echo -e "\n${GREEN}====== 正在实时追踪 Shadow-TLS v3 日志 (按 Ctrl+C 终止) ======${RESET}"
                if [ -f "/var/log/shadowtls-v6.log" ]; then tail -f /var/log/shadowtls-v6.log; else _warn "日志文件不存在"; pause; fi
                ;;
            3)
                echo -e "\n${GREEN}====== Snell v6 运行日志 ======${RESET}"
                if [ -f "/var/log/snell-v6.log" ]; then tail -n 50 /var/log/snell-v6.log; else _warn "暂无 Snell v6 日志文件"; fi
                pause
                ;;
            4)
                echo -e "\n${GREEN}====== 正在实时追踪 Snell v6 日志 (按 Ctrl+C 终止) ======${RESET}"
                if [ -f "/var/log/snell-v6.log" ]; then tail -f /var/log/snell-v6.log; else _warn "日志文件不存在"; pause; fi
                ;;
            0) break ;;
            *) _err "无效输入"; pause ;;
        esac
    done
}

# ================== 主菜单面板 ==================
show_menu() {
    clear
    local status_snell="${RED}● Snell v6未运行${RESET}"
    local status_stls="${RED}● TLS v3未运行${RESET}"
    
    rc-service snell-tlss-v6 status >/dev/null 2>&1 && status_snell="${GREEN}● Snell v6运行中${RESET}"
    rc-service shadowtlsn-v6 status >/dev/null 2>&1 && status_stls="${GREEN}● TLS v3运行中${RESET}"

    local v_snell="未安装" && [ -f "${SNELL_DIR}/version.txt" ] && v_snell="$(cat "${SNELL_DIR}/version.txt")"
    local v_stls="未安装" && [ -f "${SNELL_DIR}/stls_version.txt" ] && v_stls="$(cat "${SNELL_DIR}/stls_version.txt")"
    
    local p_stls="-"
    if [ -f "$STLS_Env" ]; then 
        p_stls=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "-")
    fi
    local p_snell="-"
    if [ -f "$SNELL_Conf" ]; then
        local raw_listen=$(_get_conf_value "listen")
        local first_listen="${raw_listen%%,*}"
        p_snell=$(echo "$first_listen" | awk -F: '{print $NF}')
    fi

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}    ◈ Snell v6 + Shadow-TLS v3 面板 ◈     ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_snell} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} ${YELLOW}Snell: v${v_snell}${RESET} | ${YELLOW}Shadow-TLS: ${v_stls}${RESET}"
    echo -e "${GREEN}运行端口 :${RESET} ${YELLOW}外网(TLS): ${p_stls}${RESET} | ${YELLOW}内部(Snell): ${p_snell}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v6 + Shadow-TLS v3${RESET}"
    echo -e "${GREEN}2. 更新 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}3. 卸载 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}6. 停止 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}7. 重启 Snell + Shadow-TLS${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    printf "\033[32m请输入选项: \033[0m"
    read -r choice || true
    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) rc-service snell-tlss-v6 start || true; rc-service shadowtlsn-v6 start || true; _info "v6 服务已启动"; pause ;;
        6) rc-service shadowtlsn-v6 stop || true; rc-service snell-tlss-v6 stop || true; _info "v6 服务已停止"; pause ;;
        7) rc-service snell-tlss-v6 restart || true; rc-service shadowtlsn-v6 restart || true; _info "v6 服务已重启"; pause ;;
        8) check_logs ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) _err "无效输入" ; pause ;;
    esac
done
