#!/usr/bin/env bash
#
# AnyTLS-RS (Rust高性能版) 一键增强部署脚本
# SPDX-License-Identifier: MIT
#
set -euo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
SCRIPT_VERSION="2.0-Rust"
SERVICE_NAME="anytls"
BINARY_NAME="anytls-server"
BINARY_DIR="/usr/local/bin"
BINARY_PATH="${BINARY_DIR}/${BINARY_NAME}"

ANYTLS_DIR="/etc/anytls"
ANYTLS_CONFIG="${ANYTLS_DIR}/config.env"
ANYTLS_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/anytls-manager.log"
RUN_USER="anytls"

TMP_DIR=$(mktemp -d -t anytls.XXXXXX)

# ================== Root 检查 ==================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 运行${RESET}"
    exit 1
fi

# ================== 清理 ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志 ==================
log() {
    echo "$(date '+%F %T') - $1" >> "$LOG_FILE"
}

pause() {
    read -n1 -s -r -p "按任意键返回菜单..." < /dev/tty
    echo
}

# ================== 用户 ==================
create_user() {
    id -u "$RUN_USER" &>/dev/null || \
        useradd -r -s /usr/sbin/nologin "$RUN_USER"
}

# ================== 公网IP ==================
get_public_ip() {
    local ip
    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && {
                echo "$ip"
                return
            }
        done
    done

    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in \
            "https://api64.ipify.org" \
            "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && {
                echo "[$ip]"
                return
            }
        done
    done

    echo "无法获取公网IP"
}

# ================== 依赖 ==================
check_deps() {
    install_pkg() {
        if command -v apt >/dev/null 2>&1; then
            apt update -y
            apt install -y "$@"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$@"
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache "$@"
        fi
    }

    command -v curl >/dev/null || install_pkg curl
    command -v wget >/dev/null || install_pkg wget
    command -v tar >/dev/null || install_pkg tar
    command -v ss >/dev/null || install_pkg iproute2
    command -v openssl >/dev/null || install_pkg openssl
}

# ================== 端口 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" | grep -q . || return 0; then
        echo -e "${RED}端口 $1 已占用${RESET}"
        return 1
    fi
}

random_port() {
    shuf -i 10000-65000 -n1
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c16 || true
}

# ================== 架构 (Rust版发布文件名转换) ==================
detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *)
            echo -e "${RED}AnyTLS-RS 暂不支持架构 $(uname -m)${RESET}"
            exit 1
            ;;
    esac
}

# ================== 获取 Rust 版最新 Release ==================
get_latest_version() {
    local latest_release
    latest_release=$(curl -fsSL --max-time 5 "https://api.github.com/repos/ssrlive/anytls-rs/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$latest_release" ]]; then
        latest_release=$(curl -fsSLI --max-time 5 "https://github.com/ssrlive/anytls-rs/releases/latest" 2>/dev/null | grep -i 'location:' | sed -E 's/.*\/v?([^/\r\n]+).*/\1/')
    fi
    echo "${latest_release:-0.3.4}"
}

# ================== 证书申请核心逻辑 ==================
inst_cert() {
    mkdir -p "$ANYTLS_DIR"

    echo "---------------------------------------------"
    echo -e "AnyTLS-RS 证书配置方式如下："
    echo -e " 1) 脚本全自动自签 ${YELLOW}（默认）${RESET}"
    echo -e " 2) Acme 脚本自动申请 (需放行 80 端口)"
    echo -e " 3) 自定义证书路径 (完美支持)"
    echo "---------------------------------------------"
    local certInput
    read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput < /dev/tty
    certInput=${certInput:-1}

    cert_path="${ANYTLS_DIR}/server.crt"
    key_path="${ANYTLS_DIR}/server.key"

    if [[ $certInput == 2 ]]; then
        if ss -tulnH "( sport = :80 )" | grep -q .; then
            echo -e "${YELLOW}[警告] 检测到 80 端口已被占用，独立申请模式可能会失败。${RESET}"
        fi

        if [[ -f "$cert_path" && -f "$key_path" && -s "$cert_path" && -s "$key_path" && -f "${ANYTLS_DIR}/ca.log" ]]; then
            anytls_domain=$(cat "${ANYTLS_DIR}/ca.log")
            echo -e "${GREEN}[信息] 检测到已有域名 [${anytls_domain}] 的证书，正在复用...${RESET}"
        else
            local vps_ip
            vps_ip=$(get_public_ip)
            read -rp "请输入需要申请证书的域名: " anytls_domain < /dev/tty
            [[ -z $anytls_domain ]] && { echo -e "${RED}[错误] 未输入域名！${RESET}"; return 1; }
            
            echo -e "${GREEN}[信息] 正在检查并安装 Acme.sh 依赖...${RESET}"
            local acme_cmd="/root/.acme.sh/acme.sh"
            if [[ ! -f "$acme_cmd" ]]; then
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
            fi
            
            "$acme_cmd" --set-default-ca --server letsencrypt
            
            echo -e "${GREEN}[信息] 正在向 Let's Encrypt 申请证书...${RESET}"
            if [[ "$vps_ip" =~ ":" ]]; then
                "$acme_cmd" --issue -d "${anytls_domain}" --standalone -k ec-256 --listen-v6 --insecure
            else
                "$acme_cmd" --issue -d "${anytls_domain}" --standalone -k ec-256 --insecure
            fi
            
            if "$acme_cmd" --install-cert -d "${anytls_domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
                echo "$anytls_domain" > "${ANYTLS_DIR}/ca.log"
                echo -e "${GREEN}[信息] Acme 证书申请并成功分发至安全沙箱！${RESET}"
            else
                echo -e "${RED}[错误] Acme 证书申请失败，自动切换回自签模式。${RESET}"
                certInput=1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        local user_cert user_key
        read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert < /dev/tty
        read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key < /dev/tty
        read -rp "请输入证书对应的域名 (SNI): " anytls_domain < /dev/tty
        
        if [[ -f "$user_cert" && -f "$user_key" ]]; then
            cp -f "$user_cert" "$cert_path"
            cp -f "$user_key" "$key_path"
            echo "$anytls_domain" > "${ANYTLS_DIR}/ca.log"
            echo -e "${GREEN}[信息] 自定义证书已成功加载到 AnyTLS 运行区。${RESET}"
        else
            echo -e "${RED}[错误] 找不到输入的证书文件，自动降级回自签模式。${RESET}"
            certInput=1
        fi
    fi

    if [[ $certInput == 1 ]]; then
        echo -e "${GREEN}[信息] 将使用自签证书 (默认伪装域名: anytls.local)${RESET}"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=anytls.local"
        anytls_domain="anytls.local"
        echo "$anytls_domain" > "${ANYTLS_DIR}/ca.log"
    fi

    chmod 644 "$cert_path"
    chmod 600 "$key_path"
    chown -R ${RUN_USER}:${RUN_USER} "$ANYTLS_DIR"
}

# ================== 配置写入 ==================
write_config() {
    mkdir -p "$ANYTLS_DIR"
    cat > "$ANYTLS_CONFIG" <<EOF
ANYTLS_PORT=$1
ANYTLS_PASSWORD=$2
ANYTLS_CERT=$3
ANYTLS_KEY=$4
EOF
    chmod 600 "$ANYTLS_CONFIG"
    chown -R ${RUN_USER}:${RUN_USER} "$ANYTLS_DIR"
}

# ================== 生成 Systemd 服务文件 (对接 Rust 传参) ==================
write_systemd_service() {
    cat > "$ANYTLS_SERVICE" <<EOF
[Unit]
Description=AnyTLS-RS Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
EnvironmentFile=${ANYTLS_CONFIG}
ExecStart=${BINARY_PATH} -l 0.0.0.0:\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD} --cert \${ANYTLS_CERT} --key \${ANYTLS_KEY} --watch-cert -L info
Restart=always
RestartSec=3

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ================== 输出节点 ==================
output_node_links() {
    local ip
    ip=$(get_public_ip)
    local hostname
    hostname=$(hostname -s | sed 's/ /_/g')

    local sni="anytls.local"
    [[ -f "${ANYTLS_DIR}/ca.log" ]] && sni=$(cat "${ANYTLS_DIR}/ca.log")

    echo -e "${GREEN}====== AnyTLS-RS 节点信息 ======${RESET}"
    echo -e "${YELLOW}IP      : ${ip}${RESET}"
    echo -e "${YELLOW}端口    : $1${RESET}"
    echo -e "${YELLOW}密码    : $2${RESET}"
    echo -e "${YELLOW}证书SNI : ${sni}${RESET}"
    echo -e "${GREEN}---------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo -e "${YELLOW}[信息] 节点连接配置提示：${RESET}"
    echo -e "${CYAN}客户端可正常连接此端口，若使用的自签证书，客户端请务必勾选 \"允许不安全连接 (Insecure)\"。${RESET}"
    echo -e "${CYAN}若使用的 Acme 或外部正规证书（如你的 Let's Encrypt），客户端关闭不安全校验即可实现安全且高隐蔽性的端到端加密传输。${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
}

# ================== 下载与分发二进制核心 ==================
download_and_extract() {
    local version=$1
    local arch
    arch=$(detect_arch)
    
    # 对接 ssrlive/anytls-rs 构建物命名格式
    local url="https://github.com/ssrlive/anytls-rs/releases/download/v${version}/anytls-v${version}-${arch}.tar.gz"

    cd "$TMP_DIR"
    wget "$url" -O anytls.tar.gz || { echo -e "${RED}下载 AnyTLS-RS 核心失败${RESET}"; return 1; }
    tar -xzvf anytls.tar.gz -C "$TMP_DIR"

    local real_binary_path
    real_binary_path=$(find "$TMP_DIR" -type f -name "$BINARY_NAME" | head -n 1)
    if [[ -z "$real_binary_path" ]]; then
        echo -e "${RED}[错误] 解压包内未找到可执行程序 ${BINARY_NAME}${RESET}"
        return 1
    fi

    install -m755 "$real_binary_path" "$BINARY_PATH"
    echo "$version" > "${ANYTLS_DIR}/version.txt"
}

# ================== 安装 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始安装 AnyTLS-RS (Rust 高性能版)...${RESET}"

    check_deps
    create_user
    mkdir -p "$ANYTLS_DIR"

    echo -e "${GREEN}[信息] 正在获取 AnyTLS-RS 最新版本...${RESET}"
    local version
    version=$(get_latest_version)
    echo -e "${GREEN}[信息] 检测到最新版本为: v${version}${RESET}"

    download_and_extract "$version" || return 1

    local port input_port
    while true; do
        read -p "请输入监听端口 (默认随机): " input_port < /dev/tty
        port=${input_port:-$(random_port)}

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            check_port "$port" || continue
            break
        fi
        echo -e "${RED}端口无效${RESET}"
    done

    local input_password password
    read -p "请输入密码 (默认随机): " input_password < /dev/tty
    password=${input_password:-$(random_password)}

    # 配置证书参数
    inst_cert || return 1

    write_config "$port" "$password" "${ANYTLS_DIR}/server.crt" "${ANYTLS_DIR}/server.key"
    write_systemd_service

    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${RED}AnyTLS-RS 启动失败，请检查以下错误日志：${RESET}"
        journalctl -u "$SERVICE_NAME" -n20 --no-pager
        return 1
    fi

    echo -e "${GREEN}[完成] AnyTLS-RS 安装成功并运行！${RESET}"
    output_node_links "$port" "$password"
    log "安装成功"
}

# ================== 更新 AnyTLS 主程序 ==================
update_ss() {
    if [[ ! -f "${ANYTLS_DIR}/version.txt" || ! -f "$ANYTLS_CONFIG" ]]; then
        echo -e "${RED}[错误] 未检测到已安装的 AnyTLS 服务，请先执行安装。${RESET}"
        return 1
    fi

    local current_version
    current_version=$(cat "${ANYTLS_DIR}/version.txt")
    
    echo -e "${GREEN}[信息] 正在获取最新版本...${RESET}"
    local latest_version
    latest_version=$(get_latest_version)

    echo -e "${GREEN}当前版本: v${current_version}${RESET}"
    echo -e "${GREEN}最新版本: v${latest_version}${RESET}"

    echo -e "${GREEN}[信息] 无阻断开始覆盖升级至 v${latest_version}...${RESET}"
    
    systemctl stop "$SERVICE_NAME" || true
    download_and_extract "$latest_version" || { systemctl start "$SERVICE_NAME"; return 1; }

    # 刷新服务并启动
    write_systemd_service
    systemctl start "$SERVICE_NAME"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}[完成] AnyTLS-RS 成功升级覆盖至 v${latest_version}!${RESET}"
        log "升级成功至 v${latest_version}"
    else
        echo -e "${RED}[错误] 升级覆盖后服务启动失败，请检查日志。${RESET}"
    fi
}

# ================== 修改配置 ==================
modify_ss() {
    [[ -f "$ANYTLS_CONFIG" ]] || {
        echo -e "${RED}配置不存在${RESET}"
        return
    }

    local ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_CERT ANYTLS_KEY
    source "$ANYTLS_CONFIG"

    echo "当前端口: $ANYTLS_PORT"
    echo "当前密码: $ANYTLS_PASSWORD"

    local port password

    read -p "新端口 [当前:${ANYTLS_PORT}]: " port < /dev/tty
    port=${port:-$ANYTLS_PORT}

    if [[ "$port" != "$ANYTLS_PORT" ]]; then
        check_port "$port" || return 1
    fi

    read -p "新密码 [默认保持]: " password < /dev/tty
    password=${password:-$ANYTLS_PASSWORD}

    echo "---------------------------------------------"
    read -rp "是否需要更新证书/重设域名 SNI？[y/N] (直接回车默认不修改): " change_cert_flag < /dev/tty
    if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
        inst_cert || return 1
    fi

    write_config "$port" "$password" "${ANYTLS_DIR}/server.crt" "${ANYTLS_DIR}/server.key"
    write_systemd_service
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}修改成功${RESET}"
    output_node_links "$port" "$password"
}

# ================== 卸载 ==================
uninstall_ss() {
    systemctl stop "$SERVICE_NAME" || true
    systemctl disable "$SERVICE_NAME" || true

    rm -f "$ANYTLS_SERVICE"
    rm -f "$BINARY_PATH"
    rm -rf "$ANYTLS_DIR"

    id -u "$RUN_USER" &>/dev/null && userdel "$RUN_USER" || true

    systemctl daemon-reload
    echo -e "${GREEN}卸载完成${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status
    systemctl is-active --quiet "$SERVICE_NAME" &&
        status="${GREEN}●运行中${RESET}" ||
        status="${RED}●未运行${RESET}"

    local version="未安装"
    [[ -f "${ANYTLS_DIR}/version.txt" ]] &&
        version="v$(cat "${ANYTLS_DIR}/version.txt")"

    local port="-"
    if [[ -f "$ANYTLS_CONFIG" ]]; then
        local ANYTLS_PORT
        source "$ANYTLS_CONFIG"
        port=$ANYTLS_PORT
    fi

    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     AnyTLS-RS 管理面板 (Rust)   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1. 安装 AnyTLS-RS${RESET}"
    echo -e "${GREEN}2. 更新 AnyTLS-RS${RESET}"
    echo -e "${GREEN}3. 卸载 AnyTLS-RS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 AnyTLS-RS${RESET}"
    echo -e "${GREEN}6. 停止 AnyTLS-RS${RESET}"
    echo -e "${GREEN}7. 重启 AnyTLS-RS${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu

    set +e
    read -r -p $'\033[32m请输入选项: \033[0m' choice < /dev/tty
    set -e

    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) systemctl start "$SERVICE_NAME"; echo -e "${GREEN}[完成] AnyTLS 已启动${RESET}"; pause ;;
        6) systemctl stop "$SERVICE_NAME"; echo -e "${GREEN}[完成] AnyTLS 已停止${RESET}"; pause ;;
        7) systemctl restart "$SERVICE_NAME"; echo -e "${GREEN}[完成] AnyTLS 已重启${RESET}"; pause ;;
        8) journalctl -u "$SERVICE_NAME" -e --no-pager; pause ;;
        9)
            if [[ -f "$ANYTLS_CONFIG" ]]; then
                local ANYTLS_PORT ANYTLS_PASSWORD
                source "$ANYTLS_CONFIG"
                output_node_links "$ANYTLS_PORT" "$ANYTLS_PASSWORD"
            else
                echo -e "${RED}[错误] 尚未生成配置文件，请先执行安装。${RESET}"
            fi
            pause
            ;;
        0) exit 0 ;;
        *)
            echo -e "${RED}无效输入${RESET}"
            pause
            ;;
    esac
done
