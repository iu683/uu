#!/bin/bash
set -euo pipefail

# =========================================================
# Snell v5 + Shadow-TLS v3 一体化独立管理脚本
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
SNELL_DIR="/etc/snell-tls"
SNELL_Conf="${SNELL_DIR}/snell-server.conf"
SNELL_File="/usr/local/bin/stls-integrated-snell-server"

STLS_Env="${SNELL_DIR}/shadow-tlsn.env"
STLS_File="/usr/local/bin/stls-integrated-shadow-tlsn"

LOG_FILE="/var/log/stls-integrated-snell-managers.log"

TMP_DIR=$(mktemp -d -t snell-v5.XXXXXX)

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
    local ip
    ip=$(curl -4fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$ip" ]]; then
        ip=$(curl -6fsSL --max-time 3 https://api64.ipify.org 2>/dev/null || echo "")
        [[ -n "$ip" ]] && echo "[$ip]" && return
    fi
    [[ -z "$ip" ]] && ip="你的服务器IP"
    echo "$ip"
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
        x86_64)  echo "linux-amd64" ;;
        aarch64) echo "linux-aarch64" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

detect_stls_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

get_latest_version() {
    local latest_version
    latest_version=$(curl -sL -A "Mozilla/5.0" "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" | grep -oE 'v5\.[0-9]+\.[0-9]+' | head -n 1 2>/dev/null || echo "")
    [[ -z "$latest_version" ]] && latest_version="v5.0.1"
    echo "$latest_version"
}

get_latest_stls_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 || echo "v0.2.25"
}

# ================== 安全的数据提取引擎 ==================
load_existing_config() {
    OLD_STLS_PORT="443"
    OLD_SNELL_PORT=""
    OLD_SNELL_PSK=""
    OLD_STLS_PWD=""
    OLD_STLS_SNI="gateway.icloud.com"
    OLD_DNS=""
    OLD_IPV6="false"
    OLD_TFO="true"

    if [[ -f "$SNELL_Conf" ]]; then
        local raw_listen
        raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_SNELL_PORT=${raw_listen#*:}
        OLD_SNELL_PSK=$(awk -F'= ' '/^psk/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_DNS=$(awk -F'= ' '/^dns/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "")
        OLD_IPV6=$(awk -F'= ' '/^ipv6/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "false")
        OLD_TFO=$(awk -F'= ' '/^tfo/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "true")
    fi

    if [[ -f "$STLS_Env" ]]; then
        OLD_STLS_PORT=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "443")
        OLD_STLS_PWD=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        
        local raw_tls
        raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        if [[ -n "$raw_tls" ]]; then
            OLD_STLS_SNI=${raw_tls%:[0-9]*}
        fi
        [[ -z "$OLD_STLS_SNI" ]] && OLD_STLS_SNI="gateway.icloud.com"
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
$HOSTNAME-Snell+ShadowTLS = snell, $IP, $stls_port, psk=$psk, version=5, tfo=$tfo, ecn=true, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-v3=true
EOF
}

# ================== 构建系统自启动服务 ==================
service() {
    id -u snell-tls &>/dev/null || useradd -r -s /usr/sbin/nologin snell-tls || true

    cat > /etc/systemd/system/snell-tlss.service <<EOF
[Unit]
Description=Snell v5 Server Service (Custom s)
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=snell-tls
Group=snell-tls
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
    systemctl enable --now snell-tlss || true
}

service_stls() {
    cat > /etc/systemd/system/shadowtlsn.service <<-EOF
[Unit]
Description=Shadow TLS Service (Custom shadowtlsn)
After=network-online.target snell-tlss.service
Wants=network-online.target systemd-networkd-wait-online.service snell-tlss.service

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
Restart=on-failure
RestartSec=5s
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
EnvironmentFile=${STLS_Env}
ExecStart=${STLS_File} server --password \$STLS_PASSWORD --listen \$STLS_LISTEN --server \$STLS_SERVER --tls \$STLS_TLS v3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtlsn || true
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
    snell_port=${raw_listen#*:}
    local psk=$(awk -F'= ' '/^psk/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "未知")
    
    local show_listen_port=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "未知")
    local stls_pwd=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "未知")
    
    local raw_tls b_sni="未知"
    raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -n "$raw_tls" ]]; then
        b_sni=${raw_tls%:[0-9]*}
    fi

    echo -e "${GREEN}====== Snell v5 + Shadow-TLS v3 配置 ======${RESET}"
    echo -e "${YELLOW} 公网 IP 地址   : ${IP}${RESET}"
    echo -e "${YELLOW} 外网公网端口   : ${show_listen_port}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码 : ${stls_pwd}${RESET}"
    echo -e "${YELLOW} SNI 伪装域名    : ${b_sni}${RESET}"
    echo -e "${YELLOW} Snell内部端口   : ${snell_port} ${RESET}"
    echo -e "${YELLOW} Snell PSK 密钥  : ${psk}${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${GREEN}[信息] Surge 5 配置:${RESET}"
    if [[ -f "${SNELL_DIR}/surge.txt" ]]; then
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

    printf "是否开启 IPv6 支持？(当前: %s, 1.开启 2.关闭, 默认 2): " "$OLD_IPV6"
    read -r input_ipv6 || input_ipv6=""
    if [[ "$input_ipv6" == "1" ]]; then ipv6="true"; elif [[ "$input_ipv6" == "2" ]]; then ipv6="false"; else ipv6="$OLD_IPV6"; fi

    printf "是否开启 TCP Fast Open？(当前: %s, 1.开启 2.关闭, 默认 1): " "$OLD_TFO"
    read -r input_tfo || input_tfo=""
    if [[ "$input_tfo" == "1" ]]; then tfo="true"; elif [[ "$input_tfo" == "2" ]]; then tfo="false"; else tfo="$OLD_TFO"; fi

    write_config "$snell_port" "$psk" "$dns" "$ipv6" "$tfo" "$stls_port" "$stls_sni" "$stls_pwd" || true
    generate_links "$snell_port" "$psk" "$tfo" "$stls_port" "$stls_sni" "$stls_pwd" || true
}

# ================== 安装入口 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始全新安装 Snell v5 & Shadow-TLS v3 核心组件...${RESET}"
    check_deps
    mkdir -p "$SNELL_DIR"
    cd "$TMP_DIR"

    VERSION=$(get_latest_version)
    ARCH=$(detect_arch)
    echo -e "${GREEN}[信息] 正在下载 Snell Server ${VERSION}...${RESET}"
    wget -O snell.zip "https://dl.nssurge.com/snell/snell-server-${VERSION}-${ARCH}.zip"
    unzip -o snell.zip && install -m 755 snell-server "$SNELL_File"
    echo "$VERSION" > "${SNELL_DIR}/version.txt"

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
    systemctl restart snell-tlss || true
    service_stls
    systemctl restart shadowtlsn || true
    
    echo -e "${GREEN}[完成] 核心配置已被覆写，服务重启完毕！${RESET}"
    print_node_info
    log "配置已被修改并安全应用"
}

# ================== 日志查看菜单 ==================
show_log_menu() {
    while true; do
        clear
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}             日志查看分类菜单              ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}1. 查看 Shadow-TLS 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}2. 实时追踪 Shadow-TLS 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}3. 查看 Snell v5 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}4. 实时追踪 Snell v5 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        
        local sub_choice
        read -r -p $'\033[32m请输入选项: \033[0m' sub_choice || true
        case $sub_choice in
            1) journalctl -u shadowtlsn -n 50 --no-pager || true; pause ;;
            2) journalctl -u shadowtlsn -f || true ;;
            3) journalctl -u snell-tlss -n 50 --no-pager || true; pause ;;
            4) journalctl -u snell-tlss -f || true ;;
            0) break ;;
            *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 更新 ==================
update_ss() {
    echo -e "${GREEN}[信息] 开始更新二进制组件...${RESET}"
    cd "$TMP_DIR"
    
    if [[ -f "$SNELL_Conf" ]]; then
        VERSION=$(get_latest_version)
        ARCH=$(detect_arch)
        wget -O snell.zip "https://dl.nssurge.com/snell/snell-server-${VERSION}-${ARCH}.zip"
        unzip -o snell.zip && install -m 755 snell-server "$SNELL_File"
        echo "$VERSION" > "${SNELL_DIR}/version.txt"
    fi

    if [[ -f "$STLS_Env" ]]; then
        STLS_VERSION=$(get_latest_stls_version)
        STLS_ARCH=$(detect_stls_arch)
        wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
        install -m 755 shadow-tls "$STLS_File"
        echo "$STLS_VERSION" > "${SNELL_DIR}/stls_version.txt"
    fi

    service_stls
    systemctl restart snell-tlss shadowtlsn || true
    echo -e "${GREEN}[完成] 更新执行完毕，服务已安全重启${RESET}"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载独立一体化服务...${RESET}"
    systemctl stop shadowtlsn snell-tlss || true
    systemctl disable shadowtlsn snell-tlss || true
    rm -f /etc/systemd/system/snell-tlss.service /etc/systemd/system/shadowtlsn.service
    rm -rf "$SNELL_DIR"
    rm -f "$SNELL_File" "$STLS_File"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] 卸载清理完毕，未对原有系统默认 Snell 产生任何干扰${RESET}"
    log "安全卸载成功"
}

# ================== 主菜单面板 ==================
show_menu() {
    clear
    local status_snell="${RED}● Snell未运行${RESET}"
    local status_stls="${RED}● TLS未运行${RESET}"
    systemctl is-active --quiet snell-tlss && status_snell="${GREEN}● Snell运行中${RESET}"
    systemctl is-active --quiet shadowtlsn && status_stls="${GREEN}● TLS运行中${RESET}"

    local v_snell="未安装" && [[ -f "${SNELL_DIR}/version.txt" ]] && v_snell="$(cat "${SNELL_DIR}/version.txt")"
    local v_stls="未安装" && [[ -f "${SNELL_DIR}/stls_version.txt" ]] && v_stls="$(cat "${SNELL_DIR}/stls_version.txt")"
    
    local p_stls="-"
    if [[ -f "$STLS_Env" ]]; then 
        p_stls=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "-")
    fi
    local p_snell="-"
    if [[ -f "$SNELL_Conf" ]]; then
        local raw_listen=$(awk -F'= ' '/^listen/{print $2}' "$SNELL_Conf" 2>/dev/null | tr -d ' \t\n' || echo "-")
        p_snell=${raw_listen#*:}
    fi

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}       Snell v5 + Shadow-TLS 管理面板       ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_snell} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} ${YELLOW}Snell: ${v_snell}${RESET} | ${YELLOW}Shadow-TLS: ${v_stls}${RESET}"
    echo -e "${GREEN}运行端口 :${RESET} ${YELLOW}外网(TLS): ${p_stls}${RESET} | ${YELLOW}内部(Snell): ${p_snell}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Snell v5 + Shadow-TLS ${RESET}"
    echo -e "${GREEN}2. 更新 Snell v5 + Shadow-TLS ${RESET}"
    echo -e "${GREEN}3. 卸载 Snell v5 + Shadow-TLS ${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell v5 + Shadow-TLS ${RESET}"
    echo -e "${GREEN}6. 停止 Snell v5 + Shadow-TLS ${RESET}"
    echo -e "${GREEN}7. 重启 Snell v5 + Shadow-TLS ${RESET}"
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
        5) systemctl start snell-tlss shadowtlsn || true; echo -e "${GREEN}[完成] 服务已启动${RESET}"; pause ;;
        6) systemctl stop shadowtlsn snell-tlss || true; echo -e "${GREEN}[完成] 服务已停止${RESET}"; pause ;;
        7) systemctl restart snell-tlss shadowtlsn || true; echo -e "${GREEN}[完成] 服务已重启${RESET}"; pause ;;
        8) show_log_menu ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}" ; pause ;;
    esac
done
