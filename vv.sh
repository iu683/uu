#!/bin/sh
# 针对 Alpine Linux 深度优化，使用标准 sh 执行
set -eu

# =========================================================
# Snell v5 + Shadow-TLS v3 一体化独立管理脚本 (Alpine )
# =========================================================

# ================== 颜色与输出函数 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

_info() { echo -e "${GREEN}[信息] $1${RESET}"; }
_warn() { echo -e "${YELLOW}[警告] $1${RESET}"; }
_err()  { echo -e "${RED}[错误] $1${RESET}"; }

# ================== 基础变量 ==================
SNELL_DIR="/etc/snell-tls"
SNELL_Conf="${SNELL_DIR}/snell-server.conf"
SNELL_File="/usr/local/bin/snell-server-v5"

STLS_Env="${SNELL_DIR}/shadow-tlsn.env"
STLS_File="/usr/local/bin/stls-integrated-shadow-tlsn"

LOG_FILE="/var/log/stls-integrated-snell-managers.log"

TMP_DIR=$(mktemp -d -t snell-v5.XXXXXX)

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
    local ip
    ip=$(curl -4fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [ -z "$ip" ]; then
        ip=$(curl -6fsSL --max-time 3 https://api64.ipify.org 2>/dev/null || echo "")
        [ -n "$ip" ] && echo "[$ip]" && return
    fi
    [ -z "$ip" ] && ip="你的服务器IP"
    echo "$ip"
}

# ================== 检查端口 ==================
check_port() {
    if ss -tulnH | grep -q ":$1 "; then
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
        x86_64)  echo "amd64" ;;
        aarch64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

detect_stls_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) _err "不支持架构: $(uname -m)" && exit 1 ;;
    esac
}

_get_snell_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" | grep -oE 'v5\.[0-9]+\.[0-9]+' | head -n 1 2>/dev/null || echo "")
    [ -z "$latest_version" ] && latest_version="v5.0.1"
    echo "$latest_version"
}

get_latest_stls_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 || echo "v0.2.25"
}

# ================== 安全的数据提取引擎 ==================
load_existing_config() {
    OLD_STLS_PORT="8443"
    OLD_SNELL_PORT=""
    OLD_SNELL_PSK=""
    OLD_STLS_PWD=""
    OLD_STLS_SNI="captive.apple.com"
    OLD_DNS=""
    OLD_IPV6="false"
    OLD_TFO="true"

    if [ -f "$SNELL_Conf" ]; then
        local raw_listen
        raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_SNELL_PORT=${raw_listen#*:}
        OLD_SNELL_PSK=$(awk -F'= ' '/^psk/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_DNS=$(awk -F'= ' '/^dns/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_IPV6=$(awk -F'= ' '/^ipv6/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "false")
        OLD_TFO=$(awk -F'= ' '/^tfo/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "true")
    fi

    if [ -f "$STLS_Env" ]; then
        OLD_STLS_PORT=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "443")
        OLD_STLS_PWD=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        
        local raw_tls
        raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        if [ -n "$raw_tls" ]; then
            OLD_STLS_SNI=${raw_tls%:[0-9]*}
        fi
        [ -z "$OLD_STLS_SNI" ] && OLD_STLS_SNI="gateway.icloud.com"
    fi
    return 0
}

# ================== 写配置核心引擎 ==================
write_config() {
    local snell_port="$1"
    local psk="$2"
    local dns="$3"
    local ipv6="$4"
    local tfo="$5"
    local stls_port="$6"
    local stls_sni="$7"
    local stls_pwd="$8"

    mkdir -p "$SNELL_DIR"

    cat > "$SNELL_Conf" <<EOF
[snell-server]
listen = 127.0.0.1:$snell_port
psk = $psk
obfs = off
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF
    chmod 600 "$SNELL_Conf"

    cat > "$STLS_Env" <<EOF
STLS_LISTEN=[::]:$stls_port
STLS_SERVER=127.0.0.1:$snell_port
STLS_TLS=$stls_sni:443
STLS_PASSWORD=$stls_pwd
EOF
    chmod 600 "$STLS_Env"

    id -u snell-tls >/dev/null 2>&1 || useradd -r -s /sbin/nologin snell-tls || true
    chown -R snell-tls:snell-tls "$SNELL_DIR"
}

# ================== 生成并保存链接 ==================
generate_links() {
    local snell_port="$1"
    local psk="$2"
    local tfo="$3"
    local stls_port="$4"
    local stls_sni="$5"
    local stls_pwd="$6"

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "server")

    cat > "${SNELL_DIR}/surge.txt" <<EOF
$HOSTNAME-Snell+ShadowTLS = snell, $IP, $stls_port, psk=$psk, version=5, tfo=$tfo, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-version=3, ecn=true
EOF
    chown snell-tls:snell-tls "${SNELL_DIR}/surge.txt" || true
}

# ================== OpenRC 服务启动脚本构建 (Alpine专属) ==================
service() {
    id -u snell-tls >/dev/null 2>&1 || useradd -r -s /sbin/nologin snell-tls || true

    cat > /etc/init.d/snell-tlss <<'EOF'
#!/sbin/openrc-run

description="Snell v5 Server Service"
command="/usr/local/bin/snell-server-v5"
command_args="-c /etc/snell-tls/snell-server.conf"
command_background="yes"
command_user="snell-tls:snell-tls"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/snell-tlss
    rc-update add snell-tlss default || true
    rc-service snell-tlss start || true
}

service_stls() {
    cat > /etc/init.d/shadowtlsn <<'EOF'
#!/sbin/openrc-run

description="Shadow TLS Service v3"
command="/usr/local/bin/stls-integrated-shadow-tlsn"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"

start_pre() {
    if [ -f /etc/snell-tls/shadow-tlsn.env ]; then
        . /etc/snell-tls/shadow-tlsn.env
    else
        eerror "Environment file /etc/snell-tls/shadow-tlsn.env missing!"
        return 1
    fi
    
    export MONOIO_FORCE_LEGACY_DRIVER=1
    command_args="--v3 server --password $STLS_PASSWORD --listen $STLS_LISTEN --server $STLS_SERVER --tls $STLS_TLS"
}

depend() {
    need net snell-tlss
    after firewall snell-tlss
}
EOF
    chmod +x /etc/init.d/shadowtlsn
    rc-update add shadowtlsn default || true
    rc-service shadowtlsn start || true
    _info "OpenRC 服务部署自启配置完成！"
}

# ================== 打印配置详情 ==================
print_node_info() {
    IP=$(get_public_ip)
    if [ ! -f "$STLS_Env" ] || [ ! -f "$SNELL_Conf" ]; then
        _err "配置文件不存在，请先选择选项【1】进行安装初始化。" && return
    fi
    
    local snell_port
    local raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "未知")
    snell_port=${raw_listen#*:}
    local psk=$(awk -F'= ' '/^psk/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "未知")
    
    local show_listen_port=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "未知")
    local stls_pwd=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "未知")
    
    local raw_tls b_sni="未知"
    raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
    if [ -n "$raw_tls" ]; then
        b_sni=${raw_tls%:[0-9]*}
    fi

    echo -e "${GREEN}====== Snell  + Shadow-TLS v3 配置 ======${RESET}"
    echo -e "${YELLOW} 公网 IP 地址   : ${IP}${RESET}"
    echo -e "${YELLOW} 外网公网端口   : ${show_listen_port}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码 : ${stls_pwd}${RESET}"
    echo -e "${YELLOW} SNI 伪装域名    : ${b_sni}${RESET}"
    echo -e "${YELLOW} Snell内部端口   : ${snell_port} ${RESET}"
    echo -e "${YELLOW} Snell PSK 密钥  : ${psk}${RESET}"
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    _info "Surge 配置:"
    if [ -f "${SNELL_DIR}/surge.txt" ]; then
        echo -e "${YELLOW}$(cat "${SNELL_DIR}/surge.txt")${RESET}"
    else
        echo "未生成配置"
    fi
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
}

# ================== 动态配置交互流 ==================
execute_configuration_flow() {
    local is_modify_mode="$1"
    
    load_existing_config || true
    
    local snell_port psk dns ipv6 tfo stls_port stls_sni stls_pwd
    local input_stls_port input_snell_port input_psk input_stls_pwd input_sni input_dns input_ipv6 input_tfo

    while true; do
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS公网端口 (当前: %s, 回车保持不修改): " "${OLD_STLS_PORT:-443}"
        else
            printf "请输入Shadow-TLS公网端口 (默认: %s, 回车直接采纳): " "${OLD_STLS_PORT:-443}"
        fi
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
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入内部Snell端口 (当前: %s, 回车保持不修改): " "$default_snell_port"
        else
            printf "请输入内部Snell端口 (随机推荐: %s, 回车直接采纳): " "$default_snell_port"
        fi
        read -r input_snell_port || input_snell_port=""
        snell_port=${input_snell_port:-$default_snell_port}

        if echo "$snell_port" | grep -qE '^[0-9]+$' && [ "$snell_port" -ge 1 ] && [ "$snell_port" -le 65535 ]; then
            if [ "$snell_port" -eq "$stls_port" ]; then
                _err "内部Snell端口绝不能与外网公网端口相同！"
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

        if [ "$is_modify_mode" = true ]; then
            printf "请输入Snell PSK密钥 (当前: %s, 回车保持不修改):\n> " "$default_psk"
        else
            printf "请输入Snell PSK密钥 (默认随机生成: %s, 回车直接采纳):\n> " "$default_psk"
        fi
        read -r input_psk || input_psk=""
        psk=${input_psk:-$default_psk}
        if [ -n "$psk" ]; then
            break
        else
            _err "PSK密钥不能为空！"
        fi
    done

    while true; do
        local default_stls_pwd=""
        default_stls_pwd=${OLD_STLS_PWD:-$(openssl rand -hex 8 2>/dev/null || echo "StlsPurePwd123456")}
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS密码 (当前: %s, 回车保持不修改): " "$default_stls_pwd"
        else
            printf "请输入Shadow-TLS密码 (默认随机生成: %s, 回车直接采纳): " "$default_stls_pwd"
        fi
        read -r input_stls_pwd || input_stls_pwd=""
        stls_pwd=${input_stls_pwd:-$default_stls_pwd}
        if [ -n "$stls_pwd" ]; then
            break
        else
            _err "密码不能为空！"
        fi
    done

    while true; do
        local default_sni=${OLD_STLS_SNI:-"gateway.icloud.com"}
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS SNI伪装域名 (当前: %s, 回车保持不修改): " "$default_sni"
        else
            printf "请输入Shadow-TLS SNI伪装域名 (默认: %s, 回车直接采纳): " "$default_sni"
        fi
        read -r input_sni || input_sni=""
        stls_sni=${input_sni:-$default_sni}
        if echo "$stls_sni" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            break
        else
            _err "伪装域名格式不正确，请输入合法的域名 (如 gateway.icloud.com)"
        fi
    done

    while true; do
        local sys_dns=""
        sys_dns=$(get_system_dns || echo "1.1.1.1,8.8.8.8")
        local default_dns=${OLD_DNS:-$sys_dns}
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Snell自定义DNS (当前: %s, 回车保持不修改): " "$default_dns"
        else
            printf "请输入Snell自定义DNS (默认采纳系统: %s, 回车直接采纳): " "$default_dns"
        fi
        read -r input_dns || input_dns=""
        dns=${input_dns:-$default_dns}
        if [ -n "$dns" ]; then
            break
        else
            _err "DNS 不能为空！"
        fi
    done

    printf "是否开启 IPv6 支持？(当前: %s, 1.开启 2.关闭, 默认 2): " "$OLD_IPV6"
    read -r input_ipv6 || input_ipv6=""
    if [ "$input_ipv6" = "1" ]; then ipv6="true"; elif [ "$input_ipv6" = "2" ]; then ipv6="false"; else ipv6="$OLD_IPV6"; fi

    printf "是否开启 TCP Fast Open？(当前: %s, 1.开启 2.关闭, 默认 1): " "$OLD_TFO"
    read -r input_tfo || input_tfo=""
    if [ "$input_tfo" = "1" ]; then tfo="true"; elif [ "$input_tfo" = "2" ]; then tfo="false"; else tfo="$OLD_TFO"; fi

    write_config "$snell_port" "$psk" "$dns" "$ipv6" "$tfo" "$stls_port" "$stls_sni" "$stls_pwd" || true
    generate_links "$snell_port" "$psk" "$tfo" "$stls_port" "$stls_sni" "$stls_pwd" || true
}

# ================== 核心 Alpine 部署与下载逻辑 ==================
_download_and_install_binary() {
    local sarch=$( _map_arch ) || { _err "不支持的架构"; return 1; }
    
    _info "正在安装 Alpine 必要系统依赖 (upx, unzip, curl, iproute2, openssl, shadow)..."
    apk add --no-cache upx unzip curl iproute2 openssl shadow >/dev/null 2>&1

    _info "正在获取官方最新稳定版版本号..."
    local version=$( _get_snell_latest_version )
    version="${version#v}"

    local tmp=$(mktemp -d)
    local download_url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"

    _info "正在下载 Snell v$version (架构: $sarch)..."
    if curl -sLo "$tmp/snell.zip" --connect-timeout 60 "$download_url"; then
        if unzip -oq "$tmp/snell.zip" -d "$tmp/"; then
            _info "检测到 Alpine 环境，正在进行 UPX 壳解压兼容处理..."
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
        fi
    else
        _err "下载失败: $download_url"
    fi
    rm -rf "$tmp"
    return 1
}

# ================== 安装入口 ==================
install_ss() {
    _info "开始全新安装 Snell & Shadow-TLS v3 核心组件..."
    mkdir -p "$SNELL_DIR"

    # 执行核心封装好的 Alpine 下载脱壳逻辑
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

    _info "服务安装部署成功，节点已启动运行！"
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
    
    execute_configuration_flow true
    
    _info "正在安全平滑重启底层 OpenRC 服务..."
    rc-service snell-tlss restart || true
    service_stls
    rc-service shadowtlsn restart || true
    
    _info "核心配置已被覆写，服务重启完毕！"
    print_node_info
    log "配置已被修改并安全应用"
}

# ================== 更新 ==================
update_ss() {
    _info "开始更新二进制组件..."
    
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

    service_stls
    rc-service snell-tlss restart || true
    rc-service shadowtlsn restart || true
    _info "更新执行完毕，服务已安全重启"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    _warn "正在卸载独立一体化服务..."
    rc-service shadowtlsn stop || true
    rc-service snell-tlss stop || true
    rc-update del shadowtlsn default || true
    rc-update del snell-tlss default || true
    rm -f /etc/init.d/snell-tlss /etc/init.d/shadowtlsn
    rm -rf "$SNELL_DIR"
    rm -f "$SNELL_File" "$STLS_File"
    _info "卸载清理完毕"
    log "安全卸载成功"
}

# ================== 主菜单面板 ==================
show_menu() {
    clear
    local status_snell="${RED}● Snell未运行${RESET}"
    local status_stls="${RED}● TLS未运行${RESET}"
    
    rc-service snell-tlss status >/dev/null 2>&1 && status_snell="${GREEN}● Snell运行中${RESET}"
    rc-service shadowtlsn status >/dev/null 2>&1 && status_stls="${GREEN}● TLS运行中${RESET}"

    local v_snell="未安装" && [ -f "${SNELL_DIR}/version.txt" ] && v_snell="$(cat "${SNELL_DIR}/version.txt")"
    local v_stls="未安装" && [ -f "${SNELL_DIR}/stls_version.txt" ] && v_stls="$(cat "${SNELL_DIR}/stls_version.txt")"
    
    local p_stls="-"
    if [ -f "$STLS_Env" ]; then 
        p_stls=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "-")
    fi
    local p_snell="-"
    if [ -f "$SNELL_Conf" ]; then
        local raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "-")
        p_snell=${raw_listen#*:}
    fi

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}        Snell  + Shadow-TLS   面板    ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_snell} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} ${YELLOW}Snell: v${v_snell}${RESET} | ${YELLOW}Shadow-TLS: ${v_stls}${RESET}"
    echo -e "${GREEN}运行端口 :${RESET} ${YELLOW}外网(TLS): ${p_stls}${RESET} | ${YELLOW}内部(Snell): ${p_snell}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell  + Shadow-TLS ${RESET}"
    echo -e "${GREEN}2. 更新 Snell  + Shadow-TLS ${RESET}"
    echo -e "${GREEN}3. 卸载 Snell  + Shadow-TLS ${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell  + Shadow-TLS ${RESET}"
    echo -e "${GREEN}6. 停止 Snell  + Shadow-TLS ${RESET}"
    echo -e "${GREEN}7. 重启 Snell  + Shadow-TLS ${RESET}"
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
        5) rc-service snell-tlss start || true; rc-service shadowtlsn start || true; _info "服务已启动"; pause ;;
        6) rc-service shadowtlsn stop || true; rc-service snell-tlss stop || true; _info "服务已停止"; pause ;;
        7) rc-service snell-tlss restart || true; rc-service shadowtlsn restart || true; _info "服务已重启"; pause ;;
        8) [ -f "/var/log/messages" ] && tail -n 50 /var/log/messages | grep -E 'snell|shadow' || echo "无法读取系统消息日志文件"; pause ;; ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) _err "无效输入" ; pause ;;
    esac
done
