#!/usr/bin/env bash
#
# Xray VLESS-HTTPUpgrade Alpine 专属管理脚本
# SPDX-License-Identifier: MIT
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
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"
readonly INIT_SERVICE_PATH="/etc/init.d/xray"
readonly INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

TMP_DIR=$(mktemp -d -p /tmp xray.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
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

# ================== 获取随机路径 ==================
get_random_path() {
    local rand_str
    rand_str=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6 2>/dev/null || echo "path$(date +%s | cut -c 8-10)")
    echo "/xray_${rand_str}"
}

# ================== 验证器 ==================
is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

is_valid_path() {
    [[ "$1" =~ ^\/[a-zA-Z0-9_\/-]*$ ]]
}

is_valid_host() {
    [[ -z "$1" ]] || [[ "$1" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

# ================== 下载官方安装脚本 ==================
download_install_script() {
    local file="$TMP_DIR/install.sh"
    info "正在下载 Xray 官方安装脚本..."

    if ! curl -fsSL "$INSTALL_SCRIPT_URL" -o "$file"; then
        error "下载 Xray 安装脚本失败"
        return 1
    fi

    chmod +x "$file"
    echo "$file"
}

# ================== 获取 Xray 状态 (OpenRC) ==================
get_xray_status() {
    if command -v rc-service &>/dev/null && rc-service xray status >/dev/null 2>&1; then
        echo -e "${GREEN}● 运行中 (OpenRC)${RESET}"
    else
        if pgrep -f "$XRAY_BINARY run" >/dev/null 2>&1; then
            echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
        else
            echo -e "${RED}● 未运行${RESET}"
        fi
    fi
}

# ================== 获取版本 ==================
get_xray_version() {
    if [[ -x "$XRAY_BINARY" ]]; then
        "$XRAY_BINARY" version 2>/dev/null \
            | grep -i "Xray" \
            | head -n 1 \
            | awk '{print $2}' || echo "未知版本(请检查gcompat环境)"
    else
        echo "未安装"
    fi
}

# ================== 获取监听地址 ==================
get_listen_ip() {
    if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '= 1'; then
        echo "0.0.0.0"
    else
        echo "::"
    fi
}

# ================== 测试配置 ==================
test_config() {
    if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" &>/dev/null; then
        info "配置检查无误 (Configuration OK)"
        return 0
    fi
    error "配置测试失败，请检查参数合法性"
    return 1
}

# ================== Alpine OpenRC 专属初始化脚本模板 ==================
write_openrc_script() {
    cat << 'EOF' > "$INIT_SERVICE_PATH"
#!/sbin/openrc-run

description="Xray VLESS-HTTPUpgrade Service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "$INIT_SERVICE_PATH"
    # 创建软链接以兼容官方安装程序的默认路径定位
    mkdir -p /etc/xray
    ln -sf "$XRAY_CONFIG" /etc/xray/config.json
}

# ================== 重启服务 (OpenRC) ==================
restart_xray() {
    if [[ ! -f "$INIT_SERVICE_PATH" ]]; then
        write_openrc_script
    fi

    if command -v rc-service &>/dev/null; then
        rc-update add xray default >/dev/null 2>&1 || true
        rc-service xray restart >/dev/null 2>&1 || true
        sleep 1.5
        if rc-service xray status >/dev/null 2>&1; then
            info "Xray 通过 OpenRC 启动成功"
            return 0
        fi
    else
        pkill -f "$XRAY_BINARY run" || true
        "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
        sleep 1
        if pgrep -f "$XRAY_BINARY run" >/dev/null 2>&1; then
            info "非 OpenRC 环境，Xray 已挂载至后台常驻进程模式运行"
            return 0
        fi
    fi

    error "Xray 启动失败"
    return 1
}

# ================== 写配置 ==================
write_config() {
    local port="$1" local uuid="$2" local path="$3" local host="$4"
    local listen_ip
    listen_ip=$(get_listen_ip)

    mkdir -p "$(dirname "$XRAY_CONFIG")"

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
    echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
    echo

    if [[ -f /root/xray_vless_httpupgrade.txt ]]; then
        echo -e "${GREEN}====== 👉 v2rayN 分享链接 ======${RESET}"
        cat /root/xray_vless_httpupgrade.txt
    fi
    echo
}

# ================== 配置 Xray ==================
configure_xray() {
    info "开始配置 Xray HTTPUpgrade..."
    local port uuid path host input_path input_host input_uuid input_port

    while true; do
        read -rp "请输入端口 (直接回车随机分配端口): " input_port
        input_port=$(echo "${input_port}" | tr -d '\r\n[:space:]')
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
        input_uuid=$(echo "${input_uuid}" | tr -d '\r\n[:space:]')
        if [[ -z "${input_uuid}" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
            break
        elif is_valid_uuid "$input_uuid"; then
            uuid="$input_uuid"
            break
        else
            error "UUID 格式无效"
        fi
    done

    while true; do
        read -rp "请输入 HTTPUpgrade 路径 (直接回车默认随机生成): " input_path
        input_path=$(echo "${input_path}" | tr -d '\r\n[:space:]')
        
        if [[ -z "$input_path" ]]; then
            path=$(get_random_path)
            info "已为您随机生成路径: $path"
            break
        elif is_valid_path "$input_path"; then
            path="$input_path"
            break
        else
            error "路径格式无效，必须以 '/' 开头且不包含特殊字符"
        fi
    done

    while true; do
        read -rp "请输入伪装Host域名 (可直接回车留空): " input_host
        input_host=$(echo "${input_host}" | tr -d '\r\n[:space:]')
        host=${input_host:-}
        if is_valid_host "$host"; then
            break
        else
            error "域名格式无效"
        fi
    done

    write_config "$port" "$uuid" "$path" "$host"
    test_config || return 1
    write_openrc_script
    generate_link
    restart_xray
    show_current_config
}

# ================== 安装 ==================
install_xray() {
    info "开始安装 Xray..."
    local install_script
    install_script=$(download_install_script) || return 1

    # 通过环境变量促使官方脚本正确适配 OpenRC 与底层路径
    XRAY_CUSTOM_AMEND_SYSTEMD=false bash "$install_script" install
    XRAY_CUSTOM_AMEND_SYSTEMD=false bash "$install_script" install-geodata
    
    configure_xray
    info "Xray 已安装完成"
}

# ================== 更新 ==================
update_xray() {
    info "更新 Xray..."
    local install_script
    install_script=$(download_install_script) || return 1

    XRAY_CUSTOM_AMEND_SYSTEMD=false bash "$install_script" install
    XRAY_CUSTOM_AMEND_SYSTEMD=false bash "$install_script" install-geodata
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

    local port uuid path host input_port input_uuid input_path input_host

    while true; do
        read -rp "请输入新端口 [当前:${old_port}, 回车不修改]: " input_port
        input_port=$(echo "${input_port}" | tr -d '\r\n[:space:]')
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
        input_uuid=$(echo "${input_uuid}" | tr -d '\r\n[:space:]')
        uuid=${input_uuid:-$old_uuid}
        if is_valid_uuid "$uuid"; then
            break
        else
            error "UUID 格式无效"
        fi
    done

    while true; do
        read -rp "请输入HTTPUpgrade 路径 [当前:${old_path}, 回车不修改, 输入'rand'重新随机生成]: " input_path
        input_path=$(echo "${input_path}" | tr -d '\r\n[:space:]')
        
        if [[ -z "$input_path" ]]; then
            path="$old_path"
            break
        elif [[ "${input_path,,}" == "rand" ]]; then
            path=$(get_random_path)
            info "已重新随机生成路径: $path"
            break
        elif is_valid_path "$input_path"; then
            path="$input_path"
            break
        else
            error "路径格式无效"
        fi
    done

    while true; do
        read -rp "请输入伪装Host域名 [当前:${old_host:-无}]: " input_host
        input_host=$(echo "${input_host}" | tr -d '\r\n[:space:]')
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
    warn "即将卸载 Xray..."

    if command -v rc-service &>/dev/null; then
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
    else
        pkill -f "$XRAY_BINARY run" || true
    fi

    local install_script
    install_script=$(download_install_script) || return 1

    bash "$install_script" remove --purge
    rm -f "$INIT_SERVICE_PATH"
    rm -f /etc/xray/config.json
    rm -f /root/xray_vless_httpupgrade.txt
    info "Xray 已彻底卸载"
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
    echo -e "${GREEN}=====( Alpine Linux OpenRC )====${RESET}"
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

# ================== 依赖检查与安装 (Alpine 原生) ==================
pre_check() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请使用 root 用户运行"
        exit 1
    fi

    if [[ ! -f /etc/alpine-release ]]; then
        warn "检测到当前环境可能不是 Alpine Linux，脚本将尝试继续运行..."
    fi

    local deps=(jq curl wget openssl ss awk grep tr)
    local missing=0

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done

    # 关键修复：Alpine 下加载官方编译版 Xray 必备静态类库兼容层
    if ! apk info -e gcompat >/dev/null 2>&1; then
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        info "正在安装 Alpine 专属依赖及核心运行库 (gcompat)..."
        apk add --no-cache jq curl wget openssl iproute2 coreutils gcompat bash || true
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
            5) 
                if command -v rc-service &>/dev/null; then
                    rc-service xray start && info "服务已成功启动"
                else
                    restart_xray
                fi
                pause ;;
            6) 
                if command -v rc-service &>/dev/null; then
                    rc-service xray stop && info "Xray 已停止"
                else
                    pkill -f "$XRAY_BINARY run" && info "Xray 进程已终止"
                fi
                pause ;;
            7) restart_xray; pause ;;
            8) 
                if [[ -f /var/log/messages ]]; then
                    echo -e "${CYAN}--- 最近 50 行核心相关系统日志 ---${RESET}"
                    tail -n 50 /var/log/messages | grep -E 'xray|supervise-daemon' || tail -n 50 /var/log/messages
                    echo "--------------------------------------"
                else
                    warn "未找到系统日志文件 /var/log/messages"
                fi
                
                if [[ -f "$XRAY_BINARY" && -f "$XRAY_CONFIG" ]]; then
                    echo -e "${YELLOW}[配置自检] 如果上面存在闪退，执行自检测试：${RESET}"
                    "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" || true
                fi
                pause ;;
            9) show_current_config; pause ;;
            0) exit 0 ;;
            *) error "无效输入"; pause ;;
        esac
    done
}

main "$@"
