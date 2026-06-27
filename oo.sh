#!/bin/bash
set -euo pipefail

# =========================================================
# Snell v6 (双栈+工作模式+DNS增强) + Shadow-TLS v3 脚本
# =========================================================

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"
Info="${GREEN}[信息]${RESET}"
Error="${RED}[错误]${RESET}"

# ================== 基础变量 ==================
SNELL_DIR="/etc/snell-tls-v6"
SNELL_Conf="${SNELL_DIR}/snell-server-v6.conf"
SNELL_File="/usr/local/bin/snell-server-v6-hybrid"

STLS_Env="${SNELL_DIR}/shadow-tlsn-v6.env"
STLS_File="/usr/local/bin/stls-integrated-shadow-tlsn-v6"

LOG_FILE="/var/log/stls-integrated-snell-managers-v6.log"

TMP_DIR=$(mktemp -d -t snell-v6-hybrid.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与暂停 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

pause() {
    echo -n "按任意键返回菜单..."
    read -n 1 -s -r || true
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

# ================== 检查依赖 ==================
check_deps() {
    echo -e "${GREEN}[信息] 检查系统依赖...${RESET}"
    install_pkg() {
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y "$@"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$@"
        fi
    }
    command -v curl >/dev/null 2>&1 || install_pkg curl
    command -v wget >/dev/null 2>&1 || install_pkg wget
    command -v tar  >/dev/null 2>&1 || install_pkg tar
    command -v unzip >/dev/null 2>&1 || install_pkg unzip
    command -v ss >/dev/null 2>&1 || {
        if command -v apt >/dev/null 2>&1; then install_pkg iproute2; else install_pkg iproute; fi
    }
    command -v openssl >/dev/null 2>&1 || install_pkg openssl
    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}

# ================== 检查端口 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" 2>/dev/null | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
    return 0
}

# ================== 辅助生成器 ==================
random_key() {
    tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c 16 || echo "SnellPskKey12345"
}

random_port() { shuf -i 2000-65000 -n 1; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," - || echo "1.1.1.1,8.8.8.8"; }

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "linux-amd64" ;;
        aarch64|arm64) echo "linux-aarch64" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

detect_stls_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

get_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
    [[ -z "$latest_version" ]] && latest_version="v6.0.0b4"
    echo "$latest_version"
}

get_latest_stls_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 || echo "v0.2.25"
}

# ================== 独立的系统用户/组生成逻辑 ==================
create_user_v6() {
    if ! getent group snell-tls-v6 >/dev/null 2>&1; then
        groupadd -r snell-tls-v6 >/dev/null 2>&1 || true
    fi
    if ! id -u snell-tls-v6 >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -g snell-tls-v6 snell-tls-v6 >/dev/null 2>&1 || true
    fi
}

# ================== 安全的数据提取引擎 ==================
load_existing_config() {
    OLD_STLS_PORT="8443"
    OLD_SNELL_PORT=""
    OLD_SNELL_PSK=""
    OLD_STLS_PWD=""
    OLD_STLS_SNI="captive.apple.com"
    OLD_DNS=""
    OLD_DNS_PREF="default"
    OLD_TFO="true"
    OLD_SNELL_MODE="default"

    if [[ -f "$SNELL_Conf" ]]; then
        local raw_listen
        raw_listen=$(grep -E '^listen\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "")
        if [[ -n "$raw_listen" ]]; then
            local first_listen="${raw_listen%%,*}"
            OLD_SNELL_PORT=${first_listen#*:}
        fi
        
        OLD_SNELL_PSK=$(grep -E '^psk\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "")
        OLD_DNS=$(grep -E '^dns\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "")
        OLD_DNS_PREF=$(grep -E '^dns-ip-preference\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "default")
        OLD_TFO=$(grep -E '^tfo\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "true")
        OLD_SNELL_MODE=$(grep -E '^mode\s*=' "$SNELL_Conf" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "default")
    fi

    if [[ -f "$STLS_Env" ]]; then
        OLD_STLS_PORT=$(grep -E '^STLS_LISTEN=' "$STLS_Env" | awk -F'=' '{print $2}' | awk -F':' '{print $NF}' | tr -d ' \t\r\n' || echo "443")
        OLD_STLS_PWD=$(grep -E '^STLS_PASSWORD=' "$STLS_Env" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "")
        
        local raw_tls
        raw_tls=$(grep -E '^STLS_TLS=' "$STLS_Env" | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || echo "")
        if [[ -n "$raw_tls" ]]; then
            OLD_STLS_SNI=${raw_tls%:[0-9]*}
        fi
        [[ -z "$OLD_STLS_SNI" ]] && OLD_STLS_SNI="captive.apple.com"
    fi
    return 0
}

# ================== 写配置核心引擎  ==================
write_config() {
    local snell_port="$1"
    local psk="$2"
    local dns="$3"
    local dns_pref="$4"
    local tfo="$5"
    local snell_mode="$6"
    local stls_port="$7"
    local stls_sni="$8"
    local stls_pwd="$9"

    mkdir -p "$SNELL_DIR"

    # Snell v6 特性升级：支持多模式选择、显式本地双栈桥接
    cat > "$SNELL_Conf" <<EOF
[snell-server]
listen = 127.0.0.1:$snell_port,[::1]:$snell_port
psk = $psk
obfs = off
mode = $snell_mode
tfo = $tfo
dns = $dns
dns-ip-preference = $dns_pref
EOF
    chmod 600 "$SNELL_Conf"

    # Shadow-TLS 外层全栈接收
    cat > "$STLS_Env" <<EOF
STLS_LISTEN=[::]:$stls_port
STLS_SERVER=127.0.0.1:$snell_port
STLS_TLS=$stls_sni:443
STLS_PASSWORD=$stls_pwd
EOF
    chmod 600 "$STLS_Env"

    create_user_v6
    chown -R snell-tls-v6:snell-tls-v6 "$SNELL_DIR"
}

# ================== 生成并保存链接 ==================
generate_links() {
    local snell_port="$1"
    local psk="$2"
    local tfo="$3"
    local snell_mode="$4"
    local stls_port="$5"
    local stls_sni="$6"
    local stls_pwd="$7"

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "server")

    # 根据选定的模式决定 Surge 客户端对应的加密选项
    local client_crypto="auto"
    if [[ "$snell_mode" == "unsafe-raw" ]]; then
        client_crypto="none"
    fi

    cat > "${SNELL_DIR}/surge-v6.txt" <<EOF
$HOSTNAME-SnellV6+ShadowTLS = snell, $IP, $stls_port, psk=$psk, version=6, mode=$snell_mode, tfo=$tfo, crypto=$client_crypto, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-version=3, ecn=true, reuse=true
EOF
    chown snell-tls-v6:snell-tls-v6 "${SNELL_DIR}/surge-v6.txt" || true
}

# ================== 构建系统自启动服务 ==================
service() {
    create_user_v6

    cat > /etc/systemd/system/snell-tlss-v6.service <<EOF
[Unit]
Description=Snell v6 Server Service (Hybrid v6)
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=snell-tls-v6
Group=snell-tls-v6
LimitNOFILE=51200
Restart=on-failure
RestartSec=5s
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SNELL_File} -c ${SNELL_Conf}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now snell-tlss-v6 || true
}

service_stls() {
    cat > /etc/systemd/system/shadowtlsn-v6.service <<-EOF
[Unit]
Description=Shadow TLS Service v3 (Hybrid v6)
After=network-online.target snell-tlss-v6.service
Wants=network-online.target systemd-networkd-wait-online.service snell-tlss-v6.service

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
Restart=on-failure
RestartSec=5s
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
EnvironmentFile=${STLS_Env}
ExecStart=${STLS_File} --v3 server --password \$STLS_PASSWORD --listen \$STLS_LISTEN --server \$STLS_SERVER --tls \$STLS_TLS

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtlsn-v6 || true
    echo -e "${Info} 服务部署自启配置完成！"
}

# ================== 打印配置详情 ==================
print_node_info() {
    IP=$(get_public_ip)
    if [[ ! -f "$STLS_Env" ]] || [[ ! -f "$SNELL_Conf" ]]; then
        echo -e "${RED}配置文件不存在，请先选择选项【1】进行安装初始化。${RESET}" && return
    fi
    
    local snell_port
    local raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "未知")
    local first_listen="${raw_listen%%,*}"
    snell_port=${first_listen#*:}
    local psk=$(awk -F'= ' '/^psk/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "未知")
    local dns_pref=$(awk -F'= ' '/^dns-ip-preference/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "default")
    local s_mode=$(awk -F'= ' '/^mode/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "default")
    
    local show_listen_port=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "未知")
    local stls_pwd=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "未知")
    
    local raw_tls b_sni="未知"
    raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -n "$raw_tls" ]]; then
        b_sni=${raw_tls%:[0-9]*}
    fi

    echo -e "${GREEN}====== Snell v6 + Shadow-TLS v3 配置 ======${RESET}"
    echo -e "${YELLOW} 外网双栈 IP 地址: ${IP}${RESET}"
    echo -e "${YELLOW} 外网TLS收发端口 : ${show_listen_port}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码 : ${stls_pwd}${RESET}"
    echo -e "${YELLOW} SNI 流量伪装域名 : ${b_sni}${RESET}"
    echo -e "${YELLOW} Snell 内网工作模式: ${s_mode}${RESET}"
    echo -e "${YELLOW} DNS 家族解析偏好 : ${dns_pref}${RESET}"
    echo -e "${YELLOW} Snell PSK 核心密钥: ${psk}${RESET}"
    echo -e "${YELLOW}📄 提示：若外网为纯 v6 VPS 架构，在下方 Surge 配置中直接替换公网 IP 为 IPv6 地址即可 ★${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${GREEN}[信息] Surge 配置格式:${RESET}"
    if [[ -f "${SNELL_DIR}/surge-v6.txt" ]]; then
        echo -e "${YELLOW}$(cat "${SNELL_DIR}/surge-v6.txt")"
    else
        echo "未生成配置"
    fi
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
}

# ================== 智能下载中枢 ==================
download_snell_core() {
    local target_ver=$1
    local target_arch=$2

    local ver_with_v="v${target_ver#v}"
    local ver_without_v="${target_ver#v}"

    local url_v="https://dl.nssurge.com/snell/snell-server-${ver_with_v}-${target_arch}.zip"
    local url_no_v="https://dl.nssurge.com/snell/snell-server-${ver_without_v}-${target_arch}.zip"

    echo -e "${GREEN}[信息] 优先尝试下载方案 A (${ver_with_v})...${RESET}"
    if wget --spider -q -T 5 "$url_v"; then
        wget -O snell.zip "$url_v"
        echo "$ver_with_v" > "${SNELL_DIR}/version.txt"
    else
        echo -e "${YELLOW}[提示] 方案 A 返回 404，自动切换方案 B (${ver_without_v})...${RESET}"
        if wget --spider -q -T 5 "$url_no_v"; then
            wget -O snell.zip "$url_no_v"
            echo "$ver_without_v" > "${SNELL_DIR}/version.txt"
        else
            echo -e "${RED}[警告] 远程正式版文件未就绪，使用 v6.0.0b4 进行弹性回滚...${RESET}"
            local fallback_url="https://dl.nssurge.com/snell/snell-server-v6.0.0b4-${target_arch}.zip"
            wget -O snell.zip "$fallback_url"
            echo "v6.0.0b4" > "${SNELL_DIR}/version.txt"
        fi
    fi
}

# ================== 交互工作流 ==================
execute_configuration_flow() {
    local is_modify_mode="$1"
    
    load_existing_config || true
    
    local snell_port psk dns dns_pref tfo snell_mode stls_port stls_sni stls_pwd
    local input_stls_port input_snell_port input_psk input_stls_pwd input_sni input_dns input_dns_pref input_tfo input_mode

    while true; do
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS公网端口 (当前: %s, 回车保持不修改): " "${OLD_STLS_PORT:-443}"
        else
            printf "请输入Shadow-TLS公网端口 (默认: %s, 回车直接采纳): " "${OLD_STLS_PORT:-443}"
        fi
        read -r input_stls_port || input_stls_port=""
        stls_port=${input_stls_port:-${OLD_STLS_PORT:-443}}

        if [[ "$stls_port" =~ ^[0-9]+$ ]] && [ "$stls_port" -ge 1 ] && [ "$stls_port" -le 65535 ]; then
            if [ "$stls_port" != "$OLD_STLS_PORT" ]; then
                check_port "$stls_port" || continue
            fi
            break
        else
            echo -e "${RED}端口格式不正确，必须在 1-65535 之间。${RESET}"
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

        if [[ "$snell_port" =~ ^[0-9]+$ ]] && [ "$snell_port" -ge 1 ] && [ "$snell_port" -le 65535 ]; then
            if [ "$snell_port" -eq "$stls_port" ]; then
                echo -e "${RED}内部Snell端口绝不能与外网公网端口相同！${RESET}"
                continue
            fi
            if [ "$snell_port" != "$OLD_SNELL_PORT" ]; then
                check_port "$snell_port" || continue
            fi
            break
        else
            echo -e "${RED}端口格式不正确，必须在 1-65535 之间。${RESET}"
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
        if [[ -n "$psk" ]]; then
            break
        else
            echo -e "${RED}PSK密钥不能为空！${RESET}"
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
        if [[ -n "$stls_pwd" ]]; then
            break
        else
            echo -e "${RED}密码不能为空！${RESET}"
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
        if [[ "$stls_sni" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}伪装域名格式不正确，请输入合法的域名 (如 gateway.icloud.com)${RESET}"
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
        if [[ -n "$dns" ]]; then
            break
        else
            echo -e "${RED}DNS 不能为空！${RESET}"
        fi
    done

    # Snell v6 新特性一：DNS IP解析优先级交互
    while true; do
        echo -e "\n${YELLOW}请选择 Snell v6 DNS 解析 IP 家族优先级 [当前: ${OLD_DNS_PREF}]：${RESET}"
        echo "1. default      (系统默认)"
        echo "2. prefer-ipv4  (IPv4 优先)"
        echo "3. prefer-ipv6  (IPv6 优先)"
        echo "4. ipv4-only    (仅解析 IPv4)"
        echo "5. ipv6-only    (仅解析 IPv6)"
        read -p "请输入选项序号 (直接回车保持当前值): " input_dns_pref_choice
        
        case ${input_dns_pref_choice:-} in
            1) dns_pref="default" ; break ;;
            2) dns_pref="prefer-ipv4" ; break ;;
            3) dns_pref="prefer-ipv6" ; break ;;
            4) dns_pref="ipv4-only" ; break ;;
            5) dns_pref="ipv6-only" ; break ;;
            "") dns_pref="${OLD_DNS_PREF}" ; break ;;
            *) echo -e "${RED}无效输入，请输入 1-5 之间的数字！${RESET}\n" ;;
        esac
    done

    # Snell v6 新特性二：工作模式切换集成
    while true; do
        local default_mode="${OLD_SNELL_MODE:-default}"
        echo -e "\n${YELLOW}请选择 Snell v6 工作模式 (当前: $default_mode)：${RESET}"
        echo "1. default     (流量混淆 + AES 加密，全能传统模式)"
        echo "2. unshaped    (禁用内部混淆，纯加密传输，吞吐能效提升约 10%)"
        echo "3. unsafe-raw  (明文不加密模式：极度适合已套用外部 Shadow-TLS 保护的环境 ★)"
        read -p "请选择序号 (直接回车保持不变): " input_mode
        case ${input_mode:-} in
            1) snell_mode="default" ; break ;;
            2) snell_mode="unshaped" ; break ;;
            3) snell_mode="unsafe-raw" ; break ;;
            "") snell_mode="$default_mode" ; break ;;
            *) echo -e "${RED}无效输入，请输入 1-3 之间的数字！${RESET}\n" ;;
        esac
    done

    printf "\n是否开启 TCP Fast Open？(当前: %s, 1.开启 2.关闭, 默认 1): " "$OLD_TFO"
    read -r input_tfo || input_tfo=""
    if [[ "$input_tfo" == "1" ]]; then tfo="true"; elif [[ "$input_tfo" == "2" ]]; then tfo="false"; else tfo="$OLD_TFO"; fi

    # 传递9个核心参数给写入引擎
    write_config "$snell_port" "$psk" "$dns" "$dns_pref" "$tfo" "$snell_mode" "$stls_port" "$stls_sni" "$stls_pwd" || true
    generate_links "$snell_port" "$psk" "$tfo" "$snell_mode" "$stls_port" "$stls_sni" "$stls_pwd" || true
}

# ================== 安装入口 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始全新安装 Snell & Shadow-TLS v3 核心组件...${RESET}"
    check_deps
    mkdir -p "$SNELL_DIR"
    cd "$TMP_DIR"

    VERSION=$(get_latest_version)
    ARCH=$(detect_arch)
    
    echo -e "${GREEN}[信息] 解析到官方目标版本: ${VERSION}...${RESET}"
    download_snell_core "$VERSION" "$ARCH"
    
    unzip -o snell.zip && install -m 755 snell-server "$SNELL_File"

    STLS_VERSION=$(get_latest_stls_version)
    STLS_ARCH=$(detect_stls_arch)
    echo -e "${GREEN}[信息] 正在下载 Shadow-TLS ${STLS_VERSION}...${RESET}"
    wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
    install -m 755 shadow-tls "$STLS_File"
    echo "$STLS_VERSION" > "${SNELL_DIR}/stls_version.txt"

    execute_configuration_flow false
    service
    service_stls

    echo -e "${GREEN}[完成] 服务安装部署成功，节点已启动运行！${RESET}"
    log "全新安装并初始化成功"
    print_node_info
}

# ================== 修改现有配置 ==================
modify_ss() {
    echo -e "${GREEN}[信息] 进入修改配置模块...${RESET}"
    if [[ ! -f "$SNELL_Conf" ]] || [[ ! -f "$STLS_Env" ]]; then
        echo -e "${RED}错误：未检测到环境配置文件，请先选择选项【1】进行完整安装！${RESET}"
        return
    fi
    
    execute_configuration_flow true
    
    echo -e "${GREEN}[管理] 正在安全平滑重启底层内核服务...${RESET}"
    systemctl restart snell-tlss-v6 || true
    service_stls
    systemctl restart shadowtlsn-v6 || true
    
    echo -e "${GREEN}[完成] 核心配置已被覆写，服务重启完毕！${RESET}"
    print_node_info
    log "配置已被修改并安全应用"
}

# ================== 日志查看菜单 ==================
show_log_menu() {
    while true; do
        clear
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}       Snell v6 + Shadow-TLS v3 日志面板      ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}1. 查看 Shadow-TLS v3 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}2. 实时追踪 Shadow-TLS v3 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}-------------------------------------------${RESET}"
        echo -e "${YELLOW}3. 查看 Snell v6 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}4. 实时追踪 Snell v6 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${RED}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        
        local sub_choice
        read -r -p $'\033[32m请输入选项: \033[0m' sub_choice || true
        case $sub_choice in
            1) journalctl -u shadowtlsn-v6 -n 50 --no-pager || true; pause ;;
            2) journalctl -u shadowtlsn-v6 -f || true ;;
            3) journalctl -u snell-tlss-v6 -n 50 --no-pager || true; pause ;;
            4) journalctl -u snell-tlss-v6 -f || true ;;
            0) break ;;
            *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 更新 ==================
update_ss() {
    echo -e "${GREEN}[信息] 开始更新 v6 二进制组件...${RESET}"
    cd "$TMP_DIR"
    
    if [[ -f "$SNELL_Conf" ]]; then
        VERSION=$(get_latest_version)
        ARCH=$(detect_arch)
        download_snell_core "$VERSION" "$ARCH"
        unzip -o snell.zip && install -m 755 snell-server "$SNELL_File"
    fi

    if [[ -f "$STLS_Env" ]]; then
        STLS_VERSION=$(get_latest_stls_version)
        STLS_ARCH=$(detect_stls_arch)
        wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
        install -m 755 shadow-tls "$STLS_File"
        echo "$STLS_VERSION" > "${SNELL_DIR}/stls_version.txt"
    fi

    service_stls
    systemctl restart snell-tlss-v6 shadowtlsn-v6 || true
    echo -e "${GREEN}[完成] 更新执行完毕，服务已安全重启${RESET}"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载服务...${RESET}"
    systemctl stop shadowtlsn-v6 snell-tlss-v6 || true
    systemctl disable shadowtlsn-v6 snell-tlss-v6 || true
    rm -f /etc/systemd/system/snell-tlss-v6.service /etc/systemd/system/shadowtlsn-v6.service
    rm -rf "$SNELL_DIR"
    rm -f "$SNELL_File" "$STLS_File"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] 卸载清理完毕${RESET}"
    log "安全卸载成功"
}

# ================== 主菜单面板 ==================
show_menu() {
    clear
    local status_snell="${RED}● Snellv6 未运行${RESET}"
    local status_stls="${RED}● TLSv3 未运行${RESET}"
    systemctl is-active --quiet snell-tlss-v6 && status_snell="${GREEN}● Snellv6 运行中${RESET}"
    systemctl is-active --quiet shadowtlsn-v6 && status_stls="${GREEN}● TLSv3 运行中${RESET}"

    local v_snell="未安装" && [[ -f "${SNELL_DIR}/version.txt" ]] && v_snell="$(cat "${SNELL_DIR}/version.txt")"
    local v_stls="未安装" && [[ -f "${SNELL_DIR}/stls_version.txt" ]] && v_stls="$(cat "${SNELL_DIR}/stls_version.txt")"
    
    local p_stls="-"
    if [[ -f "$STLS_Env" ]]; then 
        p_stls=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "-")
    fi
    local p_snell="-"
    if [[ -f "$SNELL_Conf" ]]; then
        local raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "-")
        local first_listen="${raw_listen%%,*}"
        p_snell=${first_listen#*:}
    fi

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}     ◈ Snell v6 + Shadow-TLS v3 面板 ◈    ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_snell} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} ${YELLOW}Snell: ${v_snell}${RESET} | ${YELLOW}Shadow-TLS: ${v_stls}${RESET}"
    echo -e "${GREEN}运行端口 :${RESET} ${YELLOW}外网(TLS): ${p_stls}${RESET} | ${YELLOW}内部桥接(Snell): ${p_snell}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v6  + Shadow-TLS v3${RESET}"
    echo -e "${GREEN}2. 更新 Snell  + Shadow-TLS${RESET}"
    echo -e "${GREEN}3. 卸载 Snell  + Shadow-TLS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell  + Shadow-TLS${RESET}"
    echo -e "${GREEN}6. 停止 Snell  + Shadow-TLS${RESET}"
    echo -e "${GREEN}7. 重启 Snell  + Shadow-TLS${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) systemctl start snell-tlss-v6 shadowtlsn-v6 || true; echo -e "${GREEN}[完成] v6 服务已启动${RESET}"; pause ;;
        6) systemctl stop shadowtlsn-v6 snell-tlss-v6 || true; echo -e "${GREEN}[完成] v6 服务已停止${RESET}"; pause ;;
        7) systemctl restart snell-tlss-v6 shadowtlsn-v6 || true; echo -e "${GREEN}[完成] v6 服务已重启${RESET}"; pause ;;
        8) show_log_menu ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}" ; pause ;;
    esac
done
