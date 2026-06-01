#!/bin/bash
set -euo pipefail

# =========================================================
# Shadowsocks-Rust + Shadow-TLS 一体化独立管理脚本
# SS加密方式: 2022-blake3-aes-256-gcm
# =========================================================

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 (使用独立前缀防止冲突) ==================
SS_DIR="/etc/stls-integrated-ss"
SS_CONFIG="${SS_DIR}/config.json"
SS_SERVICE="/etc/systemd/system/stls-integrated-ss.service"
BINARY_PATH="/usr/local/bin/stls-integrated-ssserver"

STLS_BINARY_PATH="/usr/local/bin/stls-integrated-shadow-tls"
STLS_SERVICE="/etc/systemd/system/stls-integrated-tls.service"
STLS_ENV_FILE="${SS_DIR}/shadow-tls.env"

LOG_FILE="/var/log/stls-integrated-manager.log"
RUN_USER="stls-integrated"
METHOD="2022-blake3-aes-256-gcm"
KEY_BYTES=32

TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与暂停 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 创建用户 ==================
create_user() {
    id -u "$RUN_USER" &>/dev/null || \
        useradd -r -s /usr/sbin/nologin "$RUN_USER"
}

# ================== 获取公网IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ipv6.ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "[$ip]" && return
        done
    done
    echo "无法获取公网IP"
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
    if ! command -v xz >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then install_pkg xz-utils; else install_pkg xz; fi
    fi
    command -v ss >/dev/null 2>&1 || {
        if command -v apt >/dev/null 2>&1; then install_pkg iproute2; else install_pkg iproute; fi
    }
    command -v openssl >/dev/null 2>&1 || install_pkg openssl
    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}

# ================== 检查端口 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

# ================== 辅助生成器与校验 ==================
random_key() { openssl rand -base64 "$KEY_BYTES" | tr -d '\n'; }
random_port() { shuf -i 2000-65000 -n 1; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -; }

validate_password() {
    local password="$1"
    if ! echo "$password" | base64 -d >/dev/null 2>&1; then
        echo -e "${RED}密码不是合法 Base64${RESET}" && return 1
    fi
    local decoded_len=$(echo "$password" | base64 -d 2>/dev/null | wc -c)
    if [[ "$decoded_len" -ne "$KEY_BYTES" ]]; then
        echo -e "${RED}密码必须为 ${KEY_BYTES} 字节${RESET}" && return 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
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
    curl -fsSL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep tag_name | cut -d '"' -f4 | sed 's/v//'
}

get_latest_stls_version() {
    curl -fsSL "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | grep tag_name | cut -d '"' -f4
}

# ================== 读取现有配置 (实现回车不更改) ==================
load_existing_config() {
    # 默认出厂初始值
    OLD_STLS_PORT="8443"
    OLD_SS_PORT=""
    OLD_SS_PWD=""
    OLD_STLS_PWD=""
    OLD_STLS_SNI="gateway.icloud.com"
    OLD_DNS=""

    if [[ -f "$SS_CONFIG" ]]; then
        OLD_SS_PORT=$(grep server_port "$SS_CONFIG" | grep -o '[0-9]\+' || echo "")
        OLD_SS_PWD=$(grep password "$SS_CONFIG" | cut -d '"' -f4 || echo "")
        OLD_DNS=$(grep -A 5 "nameserver" "$SS_CONFIG" | grep -oE '[0-9.]+' | paste -sd "," - || echo "")
    fi

    if [[ -f "$STLS_ENV_FILE" ]]; then
        local listen_line=$(grep "STLS_LISTEN=" "$STLS_ENV_FILE" | cut -d'=' -f2- || echo "")
        OLD_STLS_PORT="${listen_line##*:}"
        OLD_STLS_PWD=$(grep "STLS_PASSWORD=" "$STLS_ENV_FILE" | cut -d'=' -f2- || echo "")
        
        local tls_line=$(grep "STLS_TLS=" "$STLS_ENV_FILE" | cut -d'=' -f2- || echo "")
        OLD_STLS_SNI="${tls_line%%:*}"
    fi
}

# ================== 写配置 ==================
write_config() {
    local ss_port="$1"
    local password="$2"
    local dns="$3"
    local stls_port="$4"
    local stls_sni="$5"
    local stls_pwd="$6"

    mkdir -p "$SS_DIR"

    DNS_JSON=$(echo "$dns" | awk -F',' '{
        for(i=1;i<=NF;i++){
            gsub(/^[ \t]+|[ \t]+$/, "", $i)
            printf "%s\"%s\"", (i>1?",":""), $i
        }
    }')

    cat > "$SS_CONFIG" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $ss_port,
    "password": "$password",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [
        $DNS_JSON
    ]
}
EOF
    chmod 600 "$SS_CONFIG"

    cat > "$STLS_ENV_FILE" <<EOF
STLS_LISTEN=:::$stls_port
STLS_SERVER=127.0.0.1:$ss_port
STLS_TLS=$stls_sni:443
STLS_PASSWORD=$stls_pwd
EOF
    chmod 600 "$STLS_ENV_FILE"
    chown -R ${RUN_USER}:${RUN_USER} "$SS_DIR"
}

# ================== 生成并保存链接 ==================
generate_links() {
    local ss_port="$1"
    local password="$2"
    local stls_port="$3"
    local stls_sni="$4"
    local stls_pwd="$5"

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    ENCODED_USERINFO=$(echo -n "${METHOD}:${password}" | base64 -w 0)

    SHADOWTLS_JSON="{\"version\":\"3\",\"password\":\"${stls_pwd}\",\"host\":\"${stls_sni}\"}"
    SHADOWTLS_BASE=$(echo -n "$SHADOWTLS_JSON" | base64 -w 0)

    cat > "${SS_DIR}/ss.txt" <<EOF
ss://${ENCODED_USERINFO}@${IP}:${stls_port}/?plugin=shadow-tls%3B${SHADOWTLS_BASE}#${HOSTNAME}-STLS
EOF

    cat > "${SS_DIR}/surge.txt" <<EOF
$HOSTNAME = ss, $IP, $stls_port, encrypt-method=$METHOD, password=$password, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-version=3, tfo=true, udp-relay=true, ecn=true
EOF
}

# ================== 核心配置交互流 (只管配置，不管安装) ==================
configure_ss() {
    echo -e "${GREEN}[信息] 开始配置 Shadowsocks + Shadow-TLS 参数...${RESET}"
    load_existing_config
    
    local ss_port password dns stls_port stls_sni stls_pwd

    # 1. 自定义外网公网端口 (Shadow-TLS 端口)
    while true; do
        read -p "请输入Shadow-TLS公网端口 (回车默认/保持当前: ${OLD_STLS_PORT}): " input_stls_port
        stls_port=${input_stls_port:-$OLD_STLS_PORT}

        if [[ "$stls_port" =~ ^[0-9]+$ ]] && [[ "$stls_port" -ge 1 ]] && [[ "$stls_port" -le 65535 ]]; then
            if [[ "$stls_port" != "$OLD_STLS_PORT" ]]; then
                check_port "$stls_port" || continue
            fi
            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # 2. 自定义本地内部隔离端口 (SS 端口)
    while true; do
        local default_ss_port=$([[ -n "$OLD_SS_PORT" ]] && echo "$OLD_SS_PORT" || random_port)
        read -p "请输入内部SS端口 (回车默认/保持当前: ${default_ss_port}): " input_ss_port
        ss_port=${input_ss_port:-$default_ss_port}

        if [[ "$ss_port" =~ ^[0-9]+$ ]] && [[ "$ss_port" -ge 1 ]] && [[ "$ss_port" -le 65535 ]]; then
            if [[ "$ss_port" -eq "$stls_port" ]]; then
                echo -e "${RED}内部SS端口绝对不能与公网端口相同！${RESET}"
                continue
            fi
            if [[ "$ss_port" != "$OLD_SS_PORT" ]]; then
                check_port "$ss_port" || continue
            fi
            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # 3. SS 密码
    local default_ss_pwd=$([[ -n "$OLD_SS_PWD" ]] && echo "$OLD_SS_PWD" || random_key)
    read -p "请输入SS密码 (回车默认/保持当前配置密码): " input_password
    password=${input_password:-$default_ss_pwd}
    validate_password "$password" || return

    # 4. Shadow-TLS 密码
    local default_stls_pwd=$([[ -n "$OLD_STLS_PWD" ]] && echo "$OLD_STLS_PWD" || openssl rand -hex 16)
    read -p "请输入Shadow-TLS密码 (回车默认/保持当前: ${default_stls_pwd}): " input_stls_pwd
    stls_pwd=${input_stls_pwd:-$default_stls_pwd}

    # 5. 伪装 SNI 域名
    read -p "请输入SNI伪装域名 (回车默认/保持当前: ${OLD_STLS_SNI}): " input_sni
    stls_sni=${input_sni:-$OLD_STLS_SNI}

    # 6. DNS
    local default_dns=$([[ -n "$OLD_DNS" ]] && echo "$OLD_DNS" || get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入 DNS (回车默认/保持当前: ${default_dns}): " dns
    dns=${dns:-$default_dns}

    write_config "$ss_port" "$password" "$dns" "$stls_port" "$stls_sni" "$stls_pwd"
    generate_links "$ss_port" "$password" "$stls_port" "$stls_sni" "$stls_pwd"

    echo -e "${GREEN}[完成] 配置重写保存完毕${RESET}"
}

# ================== 打印配置详情 ==================
print_node_info() {
    IP=$(get_public_ip)
    if [[ ! -f "$STLS_ENV_FILE" ]] || [[ ! -f "$SS_CONFIG" ]]; then
        echo -e "${RED}配置文件不存在，请先选择选项【1】进行安装初始化。${RESET}" && return
    fi
    source "$STLS_ENV_FILE"
    local ss_port=$(grep server_port "$SS_CONFIG" | grep -o '[0-9]\+')
    local password=$(grep password "$SS_CONFIG" | cut -d '"' -f4)

    echo -e "${GREEN}====== Shadowsocks + Shadow-TLS 配置 ======${RESET}"
    echo -e "${YELLOW} 公网 IP 地址   : ${IP}${RESET}"
    echo -e "${YELLOW} 外网公网端口   : ${STLS_LISTEN##*:}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码 : ${STLS_PASSWORD}${RESET}"
    echo -e "${YELLOW} SNI 伪装域名    : ${STLS_TLS%% *}${RESET}"
    echo -e "${YELLOW} SS内部隔离端口  : ${ss_port} (外部不可访问)${RESET}"
    echo -e "${YELLOW} SS 密码        : ${password}${RESET}"
    echo -e "${YELLOW} 加密方式       : ${METHOD}${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"
    echo -e "${GREEN}[信息] SS 链接：${RESET}"
    cat "${SS_DIR}/ss.txt"
    echo -e ""
    echo -e "${GREEN}[信息] Surge配置:${RESET}"
    echo -e "${YELLOW}$(cat "${SS_DIR}/surge.txt")${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
}

# ================== 纯修改配置 (彻底剥离安装) ==================
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]] || [[ ! -f "$STLS_ENV_FILE" ]]; then
        echo -e "${RED}错误：未检测到已有安装，请先选择选项【1】进行安装！${RESET}" && return
    fi
    configure_ss
    systemctl restart stls-integrated-ss stls-integrated-tls
    echo -e "${GREEN}[完成] 服务配置已应用并成功重启！${RESET}"
    print_node_info
    log "独立配置已被用户手动修改并成功重启"
}

# ================== 纯环境安装与服务构建 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始全新安装 Shadowsocks-Rust & Shadow-TLS 核心组件...${RESET}"
    check_deps
    create_user
    mkdir -p "$SS_DIR"
    cd "$TMP_DIR"

    # 1. 下载并安装核心组件
    VERSION=$(get_latest_version)
    ARCH=$(detect_arch)
    echo -e "${GREEN}[信息] 正在下载 Shadowsocks-Rust v${VERSION}...${RESET}"
    wget -O ss.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"
    tar -xf ss.tar.xz && install -m 755 ssserver "$BINARY_PATH"
    echo "$VERSION" > "${SS_DIR}/version.txt"

    STLS_VERSION=$(get_latest_stls_version)
    STLS_ARCH=$(detect_stls_arch)
    echo -e "${GREEN}[信息] 正在下载 Shadow-TLS ${STLS_VERSION}...${RESET}"
    wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
    install -m 755 shadow-tls "$STLS_BINARY_PATH"
    echo "$STLS_VERSION" > "${SS_DIR}/stls_version.txt"

    # 2. 调用配置生成流程进行初始化
    configure_ss

    # 3. 部署独立的 Systemd 管理环境
    cat > "$SS_SERVICE" <<EOF
[Unit]
Description=Shadowsocks Rust Server (Integrated)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${BINARY_PATH} -c ${SS_CONFIG}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
LimitNOFILE=1048576
EOF

    cat > "$STLS_SERVICE" <<EOF
[Unit]
Description=Shadow-TLS Server Service (Integrated)
After=network-online.target stls-integrated-ss.service
Requires=stls-integrated-ss.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
EnvironmentFile=${STLS_ENV_FILE}
ExecStart=${STLS_BINARY_PATH} --fastopen --v3 server --listen \$STLS_LISTEN --server \$STLS_SERVER --tls \$STLS_TLS --password \$STLS_PASSWORD
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable stls-integrated-ss stls-integrated-tls
    systemctl restart stls-integrated-ss stls-integrated-tls
    echo -e "${GREEN}[完成] 服务安装部署成功，节点已启动运行！${RESET}"
    log "全新安装并初始化成功"
}

# ================== 更新 ==================
update_ss() {
    echo -e "${GREEN}[信息] 开始更新二进制组件...${RESET}"
    cd "$TMP_DIR"
    
    if [[ -f "$SS_CONFIG" ]]; then
        VERSION=$(get_latest_version)
        ARCH=$(detect_arch)
        wget -O ss.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"
        tar -xf ss.tar.xz && install -m 755 ssserver "$BINARY_PATH"
        echo "$VERSION" > "${SS_DIR}/version.txt"
    fi

    if [[ -f "$STLS_ENV_FILE" ]]; then
        STLS_VERSION=$(get_latest_stls_version)
        STLS_ARCH=$(detect_stls_arch)
        wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
        install -m 755 shadow-tls "$STLS_BINARY_PATH"
        echo "$STLS_VERSION" > "${SS_DIR}/stls_version.txt"
    fi

    systemctl restart stls-integrated-ss stls-integrated-tls
    echo -e "${GREEN}[完成] 更新执行完毕，服务已安全重启${RESET}"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载独立一体化服务...${RESET}"
    systemctl stop stls-integrated-tls stls-integrated-ss || true
    systemctl disable stls-integrated-tls stls-integrated-ss || true
    rm -f "$SS_SERVICE" "$STLS_SERVICE"
    rm -rf "$SS_DIR"
    rm -f "$BINARY_PATH" "$STLS_BINARY_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] 卸载清理完毕${RESET}"
    log "安全卸载成功"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status_ss="${RED}● SS未运行${RESET}"
    local status_stls="${RED}● TLS未运行${RESET}"
    systemctl is-active --quiet stls-integrated-ss && status_ss="${GREEN}● SS运行中${RESET}"
    systemctl is-active --quiet stls-integrated-tls && status_stls="${GREEN}● TLS运行中${RESET}"

    local v_ss="未安装" && [[ -f "${SS_DIR}/version.txt" ]] && v_ss="v$(cat "${SS_DIR}/version.txt")"
    local v_stls="未安装" && [[ -f "${SS_DIR}/stls_version.txt" ]] && v_stls="$(cat "${SS_DIR}/stls_version.txt")"
    local p_stls="-" && [[ -f "$STLS_ENV_FILE" ]] && { source "$STLS_ENV_FILE"; p_stls="${STLS_LISTEN##*:}"; }

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}      Shadowsocks + Shadow-TLS 管理面板     ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_ss} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} SS: ${YELLOW}${v_ss}${RESET} | Shadow-TLS: ${YELLOW}${v_stls}${RESET}"
    echo -e "${GREEN}公网端口 :${RESET} ${YELLOW}${p_stls}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}2. 更新 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}3. 卸载 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}6. 停止 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}7. 重启 Shadowsocks + Shadow-TLS${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出管理台${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) systemctl start stls-integrated-ss stls-integrated-tls; echo -e "${GREEN}[完成] 服务已启动${RESET}"; pause ;;
        6) systemctl stop stls-integrated-tls stls-integrated-ss; echo -e "${GREEN}[完成] 服务已停止${RESET}"; pause ;;
        7) systemctl restart stls-integrated-ss stls-integrated-tls; echo -e "${GREEN}[完成] 服务已重启${RESET}"; pause ;;
        8) journalctl -u stls-integrated-tls -e --no-pager; pause ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done
