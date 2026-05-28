#!/bin/bash

# =========================================================
# Xray VLESS-HTTPUpgrade 管理脚本
# =========================================================

set -Eeuo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly SCRIPT_VERSION="1.2"

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"

readonly INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

TMP_DIR=$(mktemp -d -t xray.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
info() {
    echo -e "${GREEN}[信息] $*${RESET}" >&2
}

warn() {
    echo -e "${YELLOW}[警告] $*${RESET}" >&2
}

error() {
    echo -e "${RED}[错误] $*${RESET}" >&2
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..." || true
    echo
}

# ================== 获取公网IP ==================
get_public_ip() {
    local ip

    for cmd in \
        "curl -4fsSL --max-time 5" \
        "wget -4qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    for cmd in \
        "curl -6fsSL --max-time 5" \
        "wget -6qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ipv6.ip.sb"; do

            ip=$($cmd "$url" 2>/dev/null || true)

            if [[ -n "${ip:-}" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    return 1
}

# ================== 检查端口占用 ==================
check_port() {
    local port="$1"

    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then
        return 1  # 被占用
    fi

    return 0  # 没有占用
}

# ================== 验证端口格式 ==================
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] \
        && [[ "$1" -ge 1 ]] \
        && [[ "$1" -le 65535 ]]
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

# ================== UUID验证 ==================
is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

# ================== 路径/宿主格式校验 ==================
is_valid_path() {
    [[ "$1" =~ ^\/[a-zA-Z0-9_\/\-\%]*$ ]]
}

is_valid_host() {
    [[ -z "$1" ]] || [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 下载官方安装脚本 ==================
download_install_script() {
    local file="$TMP_DIR/install.sh"

    info "正在下载 Xray 安装脚本..."

    if ! curl -fsSL "$INSTALL_SCRIPT_URL" -o "$file"; then
        error "下载 Xray 安装脚本失败"
        return 1
    fi

    chmod +x "$file"
    echo "$file"
}

# ================== 获取Xray状态 ==================
get_xray_status() {
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

# ================== 获取版本 ==================
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

# ================== 获取监听地址 ==================
get_listen_ip() {
    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null \
        | grep -q '= 1'; then
        echo "0.0.0.0"
    else
        echo "::"
    fi
}

# ================== 测试配置 ==================
test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG"; then
        info "配置检查无误 (Configuration OK)"
        return 0
    fi

    error "配置测试失败"
    return 1
}

# ================== 重启服务 ==================
restart_xray() {
    systemctl restart xray 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Xray 启动成功"
        return 0
    fi

    error "Xray 启动失败"
    journalctl -u xray -n 20 --no-pager || true
    return 1
}

# ================== 写配置 ==================
write_config() {
    local port="$1"
    local uuid="$2"
    local path="$3"
    local host="$4"

    local listen_ip
    listen_ip=$(get_listen_ip)

    mkdir -p /usr/local/etc/xray

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "${listen_ip}",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${path}",
          "host": "${host}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    }
  ]
}
EOF
}

# ================== 生成订阅 ==================
generate_link() {
    local ip
    if ! ip=$(get_public_ip); then
        error "获取公网 IP 失败"
        return 1
    fi

    local uuid port path host
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "error")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "80")
    path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path' "$XRAY_CONFIG" 2>/dev/null || echo "/download")
    host=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // ""' "$XRAY_CONFIG" 2>/dev/null || echo "")

    local display_ip="$ip"
    [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

    local hostname
    hostname=$(hostname -s 2>/dev/null | tr ' ' '_')
    [[ -z "$hostname" ]] && hostname="Xray"

    local encoded_path
    encoded_path=$(echo -n "$path" | sed 's/\//%2F/g')

    cat > /root/xray_vless_httpupgrade.txt <<EOF
vless://${uuid}@${display_ip}:${port}?encryption=none&security=none&type=httpupgrade&path=${encoded_path}&host=${host}#${hostname}-HTTPUpgrade
EOF
}

# ================== 显示配置 ==================
show_current_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip uuid port path host
    ip=$(get_public_ip || echo "未知")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
    host=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // "无"' "$XRAY_CONFIG" 2>/dev/null || echo "无")

    echo -e "${GREEN}====== 当前配置 ======${RESET}"
    echo -e "${YELLOW}IP地址        : ${ip}${RESET}"
    echo -e "${YELLOW}端口          : ${port}${RESET}"
    echo -e "${YELLOW}UUID          : ${uuid}${RESET}"
    echo -e "${YELLOW}路径 (Path)   : ${path}${RESET}"
    echo -e "${YELLOW}伪装域名(Host): ${host}${RESET}"
    echo

    if [[ -f /root/xray_vless_httpupgrade.txt ]]; then
        echo -e "${GREEN}====== VLESS 链接 ======${RESET}"
        cat /root/xray_vless_httpupgrade.txt
    fi
}

# ================== 配置 Xray ==================
configure_xray() {
    info "开始配置 Xray HTTPUpgrade..."
    local port uuid path host

    while true; do
        read -rp "请输入端口 (直接回车随机分配端口): " input_port
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

    while true; do
        read -rp "请输入UUID (默认:自动生成): " input_uuid
        if [[ -z "${input_uuid:-}" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
            break
        elif is_valid_uuid "$input_uuid"; then
            uuid="$input_uuid"
            break
        else
            error "UUID 格式无效"
        fi
    done

    while true; do
        read -rp "请输入 HTTPUpgrade 路径 (必须以/开头，默认: /download): " input_path
        path=${input_path:-/download}
        if is_valid_path "$path"; then
            break
        else
            error "路径格式无效，必须以 '/' 开头且不包含特殊字符"
        fi
    done

    while true; do
        read -rp "请输入伪装Host域名 (可直接回车留空): " input_host
        host=${input_host:-}
        if is_valid_host "$host"; then
            break
        else
            error "域名格式无效"
        fi
    done

    write_config "$port" "$uuid" "$path" "$host"
    test_config || return 1
    generate_link
    restart_xray
    show_current_config
}

# ================== 安装 ==================
install_xray() {
    info "开始安装 Xray..."
    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" install
    bash "$install_script" install-geodata
    systemctl enable xray 2>/dev/null || true
    configure_xray
    info "Xray 已安装完成"
}

# ================== 更新 ==================
update_xray() {
    info "更新 Xray..."
    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" install
    bash "$install_script" install-geodata
    restart_xray
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "配置文件不存在"
        return 1
    fi

    local old_port old_uuid old_path old_host
    old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "80")
    old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "")
    old_path=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.path' "$XRAY_CONFIG" 2>/dev/null || echo "/download")
    old_host=$(jq -r '.inbounds[0].streamSettings.httpupgradeSettings.host // ""' "$XRAY_CONFIG" 2>/dev/null || echo "")

    local port uuid path host

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        if [[ -z "$input_port" ]]; then
            port="$old_port"
            break
        elif [[ "${input_port,,}" == "rand" ]]; then
            port=$(get_random_port)
            info "已为您重分配随机端口: $port"
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

    while true; do
        read -rp "请输入UUID [当前:${old_uuid}]: " input_uuid
        uuid=${input_uuid:-$old_uuid}
        if is_valid_uuid "$uuid"; then
            break
        else
            error "UUID 格式无效"
        fi
    done

    while true; do
        read -rp "请输入HTTPUpgrade 路径 [当前:${old_path}]: " input_path
        path=${input_path:-$old_path}
        if is_valid_path "$path"; then
            break
        else
            error "路径格式无效"
        fi
    done

    while true; do
        read -rp "请输入伪装Host域名 [当前:${old_host:-无}]: " input_host
        host=${input_host:-$old_host}
        if is_valid_host "$host"; then
            break
        else
            error "域名格式无效"
        fi
    done

    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

    write_config "$port" "$uuid" "$path" "$host"
    test_config || return 1
    generate_link
    restart_xray
    info "配置修改成功"
}

# ================== 卸载 ==================
uninstall_xray() {
    warn "即将卸载 Xray"

    systemctl stop xray 2>/dev/null || true
    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" remove --purge
    rm -f /root/xray_vless_httpupgrade.txt
    info "Xray 已卸载"
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
    echo -e "${GREEN}  Xray Vless+HTTPUpgrade 面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Vless+HTTPUpgrade${RESET}"
    echo -e "${GREEN} 2. 更新 Xray${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ================== 安装依赖 ==================
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y jq curl wget openssl ca-certificates iproute2 coreutils || true
    elif command -v dnf &>/dev/null; then
        dnf install -y jq curl wget openssl ca-certificates iproute2 coreutils
    elif command -v yum &>/dev/null; then
        yum install -y jq curl wget openssl ca-certificates iproute2 coreutils
    else
        error "未知的包管理器，请手动安装所需的依赖: jq, curl, wget, openssl"
        exit 1
    fi
}

# ================== 依赖检查 ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi

    local deps=(jq curl wget openssl ss timeout)
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
            5) systemctl start xray &>/dev/null || true; restart_xray; pause ;;
            6) systemctl stop xray &>/dev/null || true; info "Xray 已停止"; pause ;;
            7) restart_xray; pause ;;
            8) journalctl -u xray -e --no-pager || true; pause ;;
            9) show_current_config; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
