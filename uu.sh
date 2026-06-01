#!/usr/bin/env bash
#
# Xray (Socks5) 控制面板 
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eeuo pipefail
export LANG=en_US.UTF-8

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly SERVICE_NAME="xraysocks5"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly LINK_FILE="/root/proxynode/socks5/xray_socks5.txt"

# 降级备用版本
readonly BACKUP_VERSION="26.3.27"

TMP_DIR=$(mktemp -d -t xray_socks.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志与交互 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# ================== 获取公网IP ==================
get_public_ip() {
    local ip

    for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ipv6.ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    return 1
}

# ================== URL 编码函数 (保障TG链接可用性) ==================
url_encode() {
    local string="${1}"
    local strlen="${#string}"
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) encoded+="$c" ;;
            * )
                printf -v o '%%%02X' "'$c"
                encoded+="$o"
                ;;
        esac
    done
    echo "${encoded}"
}

# ================== 检查端口占用 ==================
check_port() {
    local port="$1"
    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then
        return 1  # 被占用
    fi
    return 0  # 没用占用
}

# ================== 验证端口格式 ==================
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

# ================== 获取可用随机端口 ==================
get_random_port() {
    local rand_port
    while true; do
        rand_port=$((RANDOM % 55536 + 10000))
        if check_port "$rand_port"; then
            echo "$rand_port"
            return 0
        fi
    done
}

# ================== 生成随机字符串 ==================
generate_random_string() {
    local length="$1"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$((length / 2))"
    else
        tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$length" || echo "admin$(RANDOM)"
    fi
}

# ================== 架构检测 ==================
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) error "暂不支持的系统架构: $arch"; return 1 ;;
    esac
}

# ================== 自动获取最新版本号 ==================
get_latest_version() {
    local latest_version
    info "正在获取 GitHub 最新 Xray 版本号..."
    
    latest_version=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null || echo "")
        
    latest_version="${latest_version#v}"

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        warn "通过 GitHub API 获取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
        echo "$BACKUP_VERSION"
    else
        info "成功获取最新版本: v${latest_version}"
        echo "$latest_version"
    fi
}

# ================== 从GitHub下载并解压Xray ==================
download_and_extract_xray() {
    local arch version
    arch=$(get_arch) || return 1
    version=$(get_latest_version)
    
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
    local zip_file="$TMP_DIR/xray.zip"
    
    info "正在从 GitHub 下载 Xray v${version} (${arch})..."
    if ! curl -L -fsSL "$download_url" -o "$zip_file"; then
        error "从 GitHub 下载 Xray 失败，请检查网络连接。"
        return 1
    fi
    
    info "正在解压..."
    mkdir -p "$TMP_DIR/extracted"
    if ! unzip -qo "$zip_file" -d "$TMP_DIR/extracted"; then
        error "解压 Xray 压缩包失败，请确保系统已安装 unzip。"
        return 1
    fi
    
    mkdir -p "$(dirname "$XRAY_BINARY")"
    rm -f "$XRAY_BINARY"
    cp -f "$TMP_DIR/extracted/xray" "$XRAY_BINARY"
    chmod +x "$XRAY_BINARY"
    
    mkdir -p "/usr/local/share/${SERVICE_NAME}"
    cp -f "$TMP_DIR/extracted/geoip.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
    cp -f "$TMP_DIR/extracted/geosite.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
}

# ================== 配置 Systemd 服务 ==================
setup_systemd_service() {
    info "配置 Systemd 服务 [${SERVICE_NAME}]..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Socks5 Server Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
}

# ================== 获取服务状态与基础参数 ==================
get_xray_status() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_xray_version() {
    if [[ -x "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null \
            | grep -i "Xray" \
            | head -n 1 \
            | awk '{print $2}' || echo "未知"
    else
        echo "未安装"
    fi
}

get_listen_ip() {
    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '= 1'; then
        echo "0.0.0.0"
    else
        echo "::"
    fi
}

test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        info "Configuration OK"
        return 0
    fi
    error "配置测试失败"
    return 1
}

restart_xray() {
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "${SERVICE_NAME} 启动成功"
        return 0
    fi

    error "${SERVICE_NAME} 启动失败"
    journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
    return 1
}

# ================== 写底层配置 ==================
write_config() {
    local port="$1"
    local user="$2"
    local pass="$3"
    
    local listen_ip
    listen_ip=$(get_listen_ip)

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    local settings_json
    if [[ -n "$user" && -n "$pass" ]]; then
        settings_json=$(jq -n --arg u "$user" --arg p "$pass" '{"auth": "password", "accounts": [{"user": $u, "pass": $p}], "udp": true}')
    else
        settings_json=$(jq -n '{"auth": "noauth", "udp": true}')
    fi

    jq -n \
        --arg listen "${listen_ip}" \
        --argjson port "${port}" \
        --argjson settings "${settings_json}" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": [{
        "listen": $listen,
        "port": $port,
        "protocol": "socks",
        "settings": $settings,
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"]
        }
      }],
      "outbounds": [{
        "protocol": "freedom",
        "settings": {
          "domainStrategy": "UseIPv4v6"
        }
      }]
    }' > "$XRAY_CONFIG"

    chmod 644 "$XRAY_CONFIG"
}

# ================== 生成分享链接 (已集成 socks 链接与 tlink) ==================
generate_link() {
    mkdir -p "$(dirname "$LINK_FILE")"
    local ip
    if ! ip=$(get_public_ip); then
        error "获取公网 IP 失败"
        return 1
    fi

    local port user pass auth_type
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "1080")
    auth_type=$(jq -r '.inbounds[0].settings.auth' "$XRAY_CONFIG" 2>/dev/null || echo "noauth")

    # 显式初始化变量，防止 unbound 报错
    user=""
    pass=""

    if [[ "$auth_type" == "password" ]]; then
        user=$(jq -r '.inbounds[0].settings.accounts[0].user // empty' "$XRAY_CONFIG" 2>/dev/null || echo "")
        pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // empty' "$XRAY_CONFIG" 2>/dev/null || echo "")
    fi

    local display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    # 对 Telegram 链接的组件进行 URL 编码
    local enc_ip enc_user enc_pass
    enc_ip=$(url_encode "$ip")
    enc_user=$(url_encode "$user")
    enc_pass=$(url_encode "$pass")

    {
        if [[ -n "$user" && -n "$pass" ]]; then
            echo "socks://${user}:${pass}@${display_ip}:${port}"
            echo "https://t.me/socks?server=${enc_ip}&port=${port}&user=${enc_user}&pass=${enc_pass}"
        else
            echo "socks://${display_ip}:${port}"
            echo "https://t.me/socks?server=${enc_ip}&port=${port}"
        fi
    } > "$LINK_FILE"
}
# ================== 显示配置 (已美化并整合输出) ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip port auth_type user pass
    ip=$(get_public_ip || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    auth_type=$(jq -r '.inbounds[0].settings.auth' "$XRAY_CONFIG" 2>/dev/null || echo "noauth")

    # 初始化变量
    user=""
    pass=""

    echo -e "${GREEN}====== Xray Socks5 服务端配置 ======${RESET}"
    echo -e "${YELLOW}服务器公网 IP   : ${ip}${RESET}"
    echo -e "${YELLOW}服务监听端口    : ${port}${RESET}"
    
    if [[ "$auth_type" == "password" ]]; then
        user=$(jq -r '.inbounds[0].settings.accounts[0].user // empty' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
        pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // empty' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
        echo -e "${YELLOW}认证方式        : 密码认证 (Password)${RESET}"
        echo -e "${YELLOW}用户名          : ${user}${RESET}"
        echo -e "${YELLOW}密码            : ${pass}${RESET}"
    else
        echo -e "${YELLOW}认证方式        : 免密认证 (NoAuth)${RESET}"
    fi

    if [[ -f "$LINK_FILE" ]]; then
        local display_ip="$ip"
        [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

        local enc_ip enc_user enc_pass
        enc_ip=$(url_encode "$ip")
        enc_user=$(url_encode "$user")
        enc_pass=$(url_encode "$pass")

        echo -e "${GREEN}====== Socks5 配置 (已存至 $LINK_FILE) ======${RESET}"
        if [[ "$auth_type" == "password" ]]; then
            echo -e "${YELLOW}● 客户端直连格式:${RESET} socks://${user}:${pass}@${display_ip}:${port}"
            echo -e "${YELLOW}● Telegram 快捷链接:${RESET} https://t.me/socks?server=${enc_ip}&port=${port}&user=${enc_user}&pass=${enc_pass}"
        else
            echo -e "${YELLOW}● 客户端直连格式:${RESET} socks://${display_ip}:${port}"
            echo -e "${YELLOW}● Telegram快捷链接:${RESET} https://t.me/socks?server=${enc_ip}&port=${port}"
        fi
    fi
}
# ================== 核心交互配置处理 ==================
configure_xray() {
    info "开始配置 Socks5 服务端节点..."
    local port user pass auth_choice

    # 1. 端口配置
    while true; do
        read -rp "请输入监听端口 (直接回车随机分配端口): " input_port
        if [[ -z "$input_port" ]]; then
            port=$(get_random_port)
            info "已为您随机分配未被占用端口: $port"
            break
        elif is_valid_port "$input_port"; then
            if ! check_port "$input_port"; then
                error "端口 ${input_port} 已被占用，请重新输入。"
                continue
            fi
            port="$input_port"
            break
        else
            error "端口无效"
        fi
    done

    # 2. 认证模式选项
    echo -e "${GREEN}请选择认证方式:${RESET}"
    echo -e " 1. 密码认证 (需要用户名和密码)"
    echo -e " 2. 免密认证 (允许任何人直接连接)"
    while true; do
        read -rp "请输入选项 [1-2, 默认 1]: " auth_choice
        auth_choice="${auth_choice:-1}" # 默认密码认证

        if [[ "$auth_choice" == "1" ]]; then
            # 独立处理账号生成
            read -rp "请输入 Socks5 用户名 (直接回车自动随机生成): " input_user
            if [[ -z "$input_user" ]]; then
                user=$(generate_random_string 8)
                info "已自动生成随机账号：${user}"
            else
                user="$input_user"
            fi

            # 独立处理密码生成
            read -rp "请输入 Socks5 密码 (直接回车自动随机生成): " input_pass
            if [[ -z "$input_pass" ]]; then
                pass=$(generate_random_string 12)
                info "已自动生成高强度密码：${pass}"
            else
                pass="$input_pass"
            fi
            break
        elif [[ "$auth_choice" == "2" ]]; then
            user=""
            pass=""
            info "已选择：免密认证 (NoAuth)"
            break
        else
            error "输入无效，请输入 1 或 2"
        fi
    done

    write_config "$port" "$user" "$pass"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

# ================== 安装 ==================
install_xray() {
    info "开始安装 Xray 核心依赖..."
    download_and_extract_xray || return 1
    setup_systemd_service
    configure_xray
    info "安装完成并已成功启动服务: ${SERVICE_NAME}"
}

# ================== 更新 ==================
update_xray() {
    info "开始更新 Xray 程序..."
    
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "检测到服务正在运行，正在停止服务以进行更新..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi

    if ! download_and_extract_xray; then
        error "下载或安装新版本失败，尝试重新启动原服务..."
        restart_xray
        return 1
    fi
    
    if restart_xray; then
        generate_link
        info "最新版更新并启动成功！当前版本: $(get_xray_version)"
    else
        error "更新后服务启动失败，请查看日志。"
        return 1
    fi
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return 1
    fi

    local old_port old_auth old_user old_pass
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "1080")
    old_auth=$(jq -r '.inbounds[0].settings.auth' "$XRAY_CONFIG" 2>/dev/null || echo "noauth")
    
    if [[ "$old_auth" == "password" ]]; then
        old_user=$(jq -r '.inbounds[0].settings.accounts[0].user' "$XRAY_CONFIG" 2>/dev/null || echo "")
        old_pass=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$XRAY_CONFIG" 2>/dev/null || echo "")
    else
        old_user=""
        old_pass=""
    fi

    local port user pass auth_choice

    # 1. 端口修改
    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        if [[ -z "$input_port" ]]; then
            port="$old_port"
            break
        elif [[ "${input_port,,}" == "rand" ]]; then
            port=$(get_random_port)
            info "已重分配空闲随机端口: $port"
            break
        elif is_valid_port "$input_port"; then
            if [[ "$input_port" != "$old_port" ]]; then
                if ! check_port "$input_port"; then
                    error "端口 ${input_port} 已被占用，请更换。"
                    continue
                fi
            fi
            port="$input_port"
            break
        else
            error "端口无效，请输入 1-65535 之间的数字。"
        fi
    done

    # 2. 认证模式修改选项
    local current_mode="密码认证"
    [[ "$old_auth" == "noauth" ]] && current_mode="免密认证"

    echo -e "${GREEN}请选择新的认证方式 [当前: ${current_mode}]:${RESET}"
    echo -e " 1. 密码认证"
    echo -e " 2. 免密认证"
    while true; do
        read -rp "请输入选项 [1-2, 回车保持当前]: " auth_choice
        
        # 如果直接回车，保持旧的模式
        if [[ -z "$auth_choice" ]]; then
            user="$old_user"
            pass="$old_pass"
            if [[ "$old_auth" == "password" ]]; then
                read -rp "是否修改用户名？[当前:${old_user}, 回车不修改]: " input_user
                [[ -n "$input_user" ]] && user="$input_user"
                read -rp "是否修改密码？[当前:${old_pass}, 回车不修改]: " input_pass
                [[ -n "$input_pass" ]] && pass="$input_pass"
            fi
            break
        fi

        if [[ "$auth_choice" == "1" ]]; then
            read -rp "请输入新用户名 [旧:${old_user:-无}, 回车自动生成]: " input_user
            if [[ -z "$input_user" ]]; then
                user=$(generate_random_string 8)
                info "已自动生成随机账号：${user}"
            else
                user="$input_user"
            fi

            read -rp "请输入新密码 [旧:${old_pass:-无}, 回车自动生成]: " input_pass
            if [[ -z "$input_pass" ]]; then
                pass=$(generate_random_string 12)
                info "已自动生成高强度密码：${pass}"
            else
                pass="$input_pass"
            fi
            break
        elif [[ "$auth_choice" == "2" ]]; then
            user=""
            pass=""
            info "已切换为：免密认证 (NoAuth)"
            break
        else
            error "输入无效，请输入 1 或 2"
        fi
    done

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

    write_config "$port" "$user" "$pass"
    test_config || return 1
    generate_link
    restart_xray
    info "配置修改成功"
}

# ================== 卸载 ==================
uninstall_xray() {
    warn "即将卸载 ${SERVICE_NAME} 服务..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -f "$XRAY_BINARY"
    rm -rf "/usr/local/etc/${SERVICE_NAME}"
    rm -rf "/usr/local/share/${SERVICE_NAME}"
    rm -f "$LINK_FILE"
    rm -rf /root/proxynode/socks5
    
    info "服务已完全卸载并清理残留。"
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status version port_show
    status=$(get_xray_status)
    version=$(get_xray_version)
    port_show="-"

    if [[ -f "$XRAY_CONFIG" ]]; then
        port_show=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Xray Socks5 面板        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Socks5${RESET}"
    echo -e "${GREEN} 2. 更新 Xray Socks5${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray Socks5${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray Socks5${RESET}"
    echo -e "${GREEN} 6. 停止 Xray Socks5${RESET}"
    echo -e "${GREEN} 7. 重启 Xray Socks5${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 安装依赖 ==================
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget sed coreutils unzip iproute2 openssl || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget sed coreutils unzip iproute2 openssl
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget sed coreutils unzip iproute2 openssl
    else
        error "未知的包管理器，请手动补充环境包: jq, curl, wget, unzip, openssl"
        exit 1
    fi
}

# ================== 依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi

    local deps=(jq curl wget unzip ss awk sed openssl)
    local missing=0

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        info "检测到缺失依赖，正在安装..."
        install_dependencies
    fi
}

# ================== 主循环 ==================
main() {
    pre_check

    while true; do
        show_menu
        
        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) install_xray; pause ;;
            2) update_xray; pause ;;
            3) uninstall_xray; pause ;;
            4) modify_config; pause ;;
            5) systemctl start "${SERVICE_NAME}" &>/dev/null || true; restart_xray; pause ;;
            6) systemctl stop "${SERVICE_NAME}" &>/dev/null || true; info "服务已停止"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u "${SERVICE_NAME}" -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
