#!/bin/sh
set -e

# =============================================================================
#  Snell v6 Server 多实例管理面板 (Alpine Linux OpenRC 专属)
# =============================================================================

export TEMPLATE_NAME="snellv6"
export BASE_DIR="/etc/${TEMPLATE_NAME}"
export LOG_FILE="/var/log/${TEMPLATE_NAME}_manager.log"
export SNELL_USER="snellv6"
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "snell")"

export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi

# ── 工具函数 ────────────────────────────────────────────────────────────────
info() { echo -e "${BLUE}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
ok()   { echo -e "${GREEN}[成功] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键重新返回控制面板...${RESET}"; read -n 1 -s; echo; }

create_user() {
    id -u "$SNELL_USER" >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin "$SNELL_USER" 2>/dev/null || true
}

check_port_occupied() {
    local port="$1"
    if netstat -tln | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

is_valid_port() { echo "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_valid_alias() { echo "$1" | grep -Eq '^[a-zA-Z0-9_-]+$'; }
random_key() { cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 16; }
random_port() { awk 'BEGIN{srand();print int(rand()*(65000-2000+1))+2000}'; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -; }

get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    if [ "$mode" = "v4" ]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return 0
        done
    elif [ "$mode" = "v6" ]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1"
}

# ── 注册表管理系统 ──────────────────────────────────────────────────────────
register_instance() {
    local name="$1"
    mkdir -p "$BASE_DIR" && touch "$REGISTRY_FILE"
    if ! grep -q "^${name}$" "$REGISTRY_FILE" 2>/dev/null; then
        echo "$name" >> "$REGISTRY_FILE"
    fi
}

unregister_instance() {
    local name="$1"
    if [ -f "$REGISTRY_FILE" ]; then
        sed -i "/^${name}$/d" "$REGISTRY_FILE"
    fi
}

sync_registry() {
    mkdir -p "$BASE_DIR" && touch "$REGISTRY_FILE"
    local temp_reg=$(mktemp)
    for f in "${BASE_DIR}"/config_*.conf; do
        [ -e "$f" ] || continue
        local name=$(basename "$f" | sed 's/^config_//;s/\.conf$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

# ── 智能内核管理 ────────────────────────────────────────────────────────────
get_latest_snell_version() {
    local latest_version=""
    latest_version=$(curl -sL --connect-timeout 4 -A "Mozilla/5.0" \
        "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | \
        grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
        
    if [ -z "$latest_version" ]; then
        latest_version="v6.0.0b4" 
    fi
    echo "$latest_version"
}

download_and_extract_snell() {
    local RAW_VERSION=$1
    local ARCH=$(uname -m)
    
    echo -e "${YELLOW}[INFO] 正在检测并安装系统必要组件...${RESET}"
    # 移除 >/dev/null 2>&1，让错误暴露出来，方便排查
    if ! apk add --no-cache unzip curl libstdc++ libgcc; then
        echo -e "${RED}[错误] 依赖安装失败！请检查系统 apk 包管理器状态。${RESET}" >&2
        exit 1
    fi

    local URL_ARCH
    case "$ARCH" in
        aarch64|arm64)              URL_ARCH="linux-aarch64" ;;
        x86_64|amd64)               URL_ARCH="linux-amd64" ;;
        *) error "不支持的系统架构: ${ARCH}"; return 1 ;;
    esac

    local VERSION_WITHOUT_V="${RAW_VERSION#v}"
    local VERSION_WITH_V="v${VERSION_WITHOUT_V}"

    local URLS="
    https://dl.nssurge.com/snell/snell-server-${VERSION_WITH_V}-${URL_ARCH}.zip
    https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}-${URL_ARCH}.zip
    "

    local success=false
    local tmp=$(mktemp -d)
    for url in $URLS; do
        echo -e "${YELLOW}正在尝试下载内核: ${url}${RESET}"
        if curl -sL -A "Mozilla/5.0" -o "$tmp/snell.zip" --connect-timeout 8 "$url" && unzip -t "$tmp/snell.zip" >/dev/null 2>&1; then
            success=true && break
        fi
    done

    if [ "$success" = false ]; then
        echo -e "${YELLOW}动态获取的路径可能已失效，使用标准保底渠道下载...${RESET}"
        local FALLBACK_URL="https://dl.nssurge.com/snell/snell-server-v6.0.0b4-${URL_ARCH}.zip"
        curl -sL -A "Mozilla/5.0" -o "$tmp/snell.zip" "$FALLBACK_URL" || { error "下载 Snell 核心引擎失败！"; rm -rf "$tmp"; return 1; }
    fi

    unzip -oq "$tmp/snell.zip" -d "$BASE_DIR"
    rm -rf "$tmp"
    chmod +x "$BASE_DIR/snell-server"
    echo -e "${YELLOW}Snell 二进制核心解压成功！${RESET}"
}

# ── 【核心修复】补齐并增强配置摘要打印函数 ───────────────────────────────────
print_instance_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.conf"
    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}无法找到实例 [ ${instance} ] 的配置文件！${RESET}"
        return
    fi

    echo -e "\n${GREEN}====== Snell v6 实例${RESET} ${YELLOW}[ ${instance} ]${RESET} ${GREEN}配置详情 ======${RESET}"
    echo -e "${GREEN} 绑定监听 (Listen) :${RESET} $(grep '^listen' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} 密钥 (PSK)        :${RESET} $(grep '^psk' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} 工作模式 (Mode)   :${RESET} $(grep '^mode' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} Fast Open (TFO)   :${RESET} $(grep '^tfo' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN}---------------------------------------${RESET}"
    if [ -f "${BASE_DIR}/link_${instance}.txt" ]; then
        echo -e "${GREEN}[Surge 节点配置] :${RESET}"
        echo -e "${YELLOW}$(cat "${BASE_DIR}/link_${instance}.txt")${RESET}\n"
    fi
}

write_config() {
    local instance="$1" port="$2" psk="$3" mode="$4" listen_mode="$5" dns_pref="$6" obfs="$7" tfo="$8" dns="$9"
    local conf_file="${BASE_DIR}/config_${instance}.conf"
    
    mkdir -p "$BASE_DIR"

    local real_listen=""
    case "$listen_mode" in
        *"0.0.0.0"*) real_listen="0.0.0.0:${port}" ;;
        *"[::]"*)    real_listen="[::]:${port}" ;;
        *)           # 严格遵循新版 --help 规范，双栈用逗号分隔，且中间不留空格
                     real_listen="0.0.0.0:${port},[::]:${port}" ;; 
    esac

    cat > "$conf_file" <<EOF
[snell-server]
listen = ${real_listen}
psk = ${psk}
mode = ${mode}
obfs = ${obfs}
tfo = ${tfo}
dns = ${dns}
dns-ip-preference = ${dns_pref}
EOF

    chmod 600 "$conf_file"
    chown -R "$SNELL_USER" "$BASE_DIR" 2>/dev/null || true
    register_instance "$instance"

    local ip=$(get_public_ip "auto")
    local display_ip="$ip"
    if echo "$ip" | grep -q ":"; then display_ip="[$ip]"; fi
    
    cat > "${BASE_DIR}/link_${instance}.txt" <<EOF
Alpine-${instance}-SnellV6 = snell, ${display_ip}, ${port}, psk=${psk}, version=6, mode=${mode}, tfo=${tfo}, reuse=true, ecn=true
EOF
}

write_openrc_template() {
    cat > /etc/init.d/snellv6 << 'EOF'
#!/sbin/openrc-run

INSTANCE_NAME="${RC_SVCNAME#snellv6.}"
[ "$INSTANCE_NAME" = "snellv6" ] && INSTANCE_NAME="snell"

description="Snell Server v6 Dynamic Instance Node (${INSTANCE_NAME})"
command="/etc/snellv6/snell-server"
command_args="-c /etc/snellv6/config_${INSTANCE_NAME}.conf"
command_background="yes"
pidfile="/run/snellv6_${INSTANCE_NAME}.pid"
output_log="/var/log/snellv6_${INSTANCE_NAME}.log"
error_log="/var/log/snellv6_${INSTANCE_NAME}.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/snellv6
}

menu_install_instance() {
    create_user
    mkdir -p "$BASE_DIR"

    local is_edit=false
    if [ "${1:-}" = "edit" ]; then is_edit=true; fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    
    local old_port old_key old_mode old_listen old_dns_pref old_obfs old_tfo old_dns
    if [ "$is_edit" = "true" ] && [ -f "$conf_file" ]; then
        echo -e "\n${GREEN}==== [正在修改实例: ${CURRENT_INSTANCE}] ====${RESET}"
        old_listen=$(grep '^listen[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_port=$(echo "$old_listen" | awk -F: '{print $NF}' | cut -d',' -f1 || echo "")
        old_key=$(grep '^psk[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_mode=$(grep '^mode[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_obfs=$(grep '^obfs[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_tfo=$(grep '^tfo[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_dns=$(grep -E '^dns[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_dns_pref=$(grep '^dns-ip-preference[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        
        # 兜底保底，防止配置文件残缺导致空变量
        [ -z "$old_port" ] && old_port="6522"
        [ -z "$old_key" ] && old_key=$(random_key)
        [ -z "$old_mode" ] && old_mode="default"
        [ -z "$old_obfs" ] && old_obfs="off"
        [ -z "$old_tfo" ] && old_tfo="true"
        [ -z "$old_dns" ] && old_dns="8.8.8.8,8.8.4.4"
        [ -z "$old_dns_pref" ] && old_dns_pref="default"
    else
        if [ -f "$conf_file" ]; then
            echo -e "${YELLOW}[WARN]检测到该实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
            local confirm=""
            read -r -p "$(echo -e "${GREEN}是否强行完全覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
            [[ "$confirm" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新 Snell 矩阵实例: ${CURRENT_INSTANCE}] ====${RESET}"
        old_port=$(random_port)
        while ! check_port_occupied "$old_port"; do old_port=$(random_port); done
        old_key=$(random_key)
        old_mode="default"
        old_obfs="off"
        old_tfo="true"
        old_dns=$(get_system_dns)
        [ -z "$old_dns" ] && old_dns="1.1.1.1,8.8.8.8"
        old_dns_pref="default"
    fi

    # 1. 端口引导
    local input_port="" opt_port=""
    while true; do
        echo -n -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${old_port}${GREEN}]: ${RESET}"
        read -r input_port
        opt_port="${input_port:-$old_port}"
        if is_valid_port "$opt_port"; then
            if [ "$opt_port" != "$old_port" ] || [ "$is_edit" = "false" ]; then
                if ! check_port_occupied "$opt_port"; then
                    echo -e "${RED}[ERROR]端口 ${opt_port} 目前正被其他进程占用，请换个端口！${RESET}" >&2
                    continue
                fi
            fi
            break
        else
            echo -e "${RED}[ERROR]端口无效，请输入 1-65535 之间的整数数值。${RESET}" >&2
        fi
    done

    # 2. 密钥引导
    local input_key="" opt_key=""
    echo -n -e "${GREEN}请输入 PSK 密钥 [当前: ${YELLOW}${old_key}${GREEN}]: ${RESET}"
    read -r input_key
    opt_key="${input_key:-$old_key}"

    # 3. 混淆加密模式
    echo -e "${YELLOW}请选择 Snell 工作模式 (mode):${RESET}"
    echo "1. default     (流量混淆 + AES 加密)"
    echo "2. unshaped    (禁用混淆，仅加密。吞吐增高，等同于 v3)"
    echo "3. unsafe-raw  (纯明文传输模式：禁用加密混淆)"
    local choice_mode="" opt_mode="$old_mode"
    echo -n "请选择 (直接回车保持当前): "
    read -r choice_mode
    case "$choice_mode" in
        1) opt_mode="default" ;;
        2) opt_mode="unshaped" ;;
        3) opt_mode="unsafe-raw" ;;
    esac

    # 4. 监听网络模式
    echo -e "${YELLOW}请选择网络双栈绑定模式:${RESET}"
    echo "1. 同时绑定监听 IPv4 & IPv6 (双栈共存推荐)"
    echo "2. 仅绑定监听 IPv4 (0.0.0.0)"
    echo "3. 仅绑定监听 IPv6 ([::])"
    local choice_listen="" opt_listen=""
    echo -n "请选择 (直接回车保持默认/当前): "
    read -r choice_listen
    case "$choice_listen" in
        2) opt_listen="0.0.0.0:${opt_port}" ;;
        3) opt_listen="[::]:${opt_port}" ;;
        1) opt_listen="0.0.0.0:${opt_port},[::]:${opt_port}" ;;
        *) opt_listen=${old_listen:-"0.0.0.0:${opt_port},[::]:${opt_port}"} ;;
    esac

    # 5. 家族优先级
    echo -e "${YELLOW}请选择 DNS 解析家族优先级 (dns-ip-preference):${RESET}"
    echo "1. default     2. prefer-ipv4     3. prefer-ipv6     4. ipv4-only     5. ipv6-only"
    local choice_pref="" opt_pref="$old_dns_pref"
    echo -n "请选择 (回车保持): "
    read -r choice_pref
    case "$choice_pref" in
        1) opt_pref="default" ;;
        2) opt_pref="prefer-ipv4" ;;
        3) opt_pref="prefer-ipv6" ;;
        4) opt_pref="ipv4-only" ;;
        5) opt_pref="ipv6-only" ;;
    esac

    # 6. OBFS 混淆
    echo -e "${YELLOW}配置高级 OBFS 混淆 [不推荐无故开启]:${RESET}"
    echo "1. TLS    2. HTTP    3. 关闭"
    local choice_obfs="" opt_obfs="$old_obfs"
    echo -n "请选择 (回车保持): "
    read -r choice_obfs
    case "$choice_obfs" in
        1) opt_obfs="tls" ;;
        2) opt_obfs="http" ;;
        3) opt_obfs="off" ;;
    esac

    # 7. TFO
    local choice_tfo="" opt_tfo="$old_tfo"
    echo -n -e "${GREEN}是否开启 TCP Fast Open？(1.开启 2.关闭) [当前: ${old_tfo}]: ${RESET}"
    read -r choice_tfo
    [ "$choice_tfo" = "1" ] && opt_tfo="true"
    [ "$choice_tfo" = "2" ] && opt_tfo="false"

    # 8. DNS
    local input_dns="" opt_dns=""
    echo -n -e "${GREEN}请输入上游解析 DNS [当前: ${YELLOW}${old_dns}${GREEN}]: ${RESET}"
    read -r input_dns
    opt_dns="${input_dns:-$old_dns}"

    # 下发安装与应用
    if [ ! -f "$BASE_DIR/snell-server" ]; then
        echo -e "${YELLOW}正在检测并部署 Snell 核心运行时...${RESET}"
        local VER=$(get_latest_snell_version)
        download_and_extract_snell "$VER"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_port" "$opt_key" "$opt_mode" "$opt_listen" "$opt_pref" "$opt_obfs" "$opt_tfo" "$opt_dns"
    write_openrc_template

    echo -e "${YELLOW}正在通知 OpenRC 矩阵控制系统生成独立子服务...${RESET}"
    ln -sf "/etc/init.d/snellv6" "/etc/init.d/snellv6.${CURRENT_INSTANCE}"
    rc-update add "snellv6.${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    
    rc-service "snellv6.${CURRENT_INSTANCE}" stop >/dev/null 2>&1 || true
    pkill -9 -f "config_${CURRENT_INSTANCE}.conf" || true
    rc-service "snellv6.${CURRENT_INSTANCE}" start >/dev/null 2>&1 || true

    sleep 1
    if rc-service "snellv6.${CURRENT_INSTANCE}" status 2>&1 | grep -q "started"; then
        echo -e "${YELLOW}实例 [ ${CURRENT_INSTANCE} ] 多开分流矩阵启动成功！${RESET}"
        print_instance_summary "$CURRENT_INSTANCE"
    else
        echo -e "${RED}[INFO]实例下发完成，但 OpenRC 响应拉起失败，请检查端口是否冲突或选择 [8] 查看实时日志。${RESET}"
    fi
}

menu_uninstall_instance() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    local confirm=""
    read -r -p "$(echo -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    rc-service "snellv6.${CURRENT_INSTANCE}" stop >/dev/null 2>&1 || true
    rc-update del "snellv6.${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    rm -f "/etc/init.d/snellv6.${CURRENT_INSTANCE}"
    
    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    rm -f "${BASE_DIR}/link_${CURRENT_INSTANCE}.txt"
    rm -f "/var/log/snellv6_${CURRENT_INSTANCE}.log"
    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}[OK]实例 [ ${CURRENT_INSTANCE} ] 现场清理干净。${RESET}"

    if [ -d "$BASE_DIR" ] && [ -z "$(ls -A "$BASE_DIR" | grep 'config_')" ]; then
        echo -e "${YELLOW}[INFO]检测到矩阵内所有实例已被排空，自动触发全局常驻组件垃圾回收机制...${RESET}"
        rm -f /etc/init.d/snellv6
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}[OK]全系统干净卸载，基础常驻依赖与核心已全部解绑！${RESET}"
        CURRENT_INSTANCE="snell"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [多开实例 OpenRC 节点矩阵管理中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    sync_registry
    local instance_list=""
    local count=0

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.conf"
            [ -f "$c_file" ] || continue

            count=$((count + 1))
            instance_list="${instance_list} ${name}"
            
            local port_num=$(grep '^listen' "$c_file" | awk -F: '{print $NF}' | cut -d',' -f1)
            local status_str="${RED}已停止${RESET}"
            rc-service "snellv6.${name}" status 2>&1 | grep -q "started" && status_str="${GREEN}运行中${RESET}"
            
            echo -e " ${CYAN}[ ${count} ] ->${GREEN} 实例名: ${YELLOW}${name}${RESET} ${GREEN}[绑定端口: ${port_num} | 运行状态: ${status_str}]${GREEN}"
        done < "$REGISTRY_FILE"
    fi

    [ "$count" -eq 0 ] && echo -e " ${YELLOW}(当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)${RESET}"
    
    echo ""
    echo -e "${GREEN}👉 输入已有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文别名】来新建独立多开实例${RESET}"
    local input_val=""
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true

    if [ -z "$input_val" ]; then return; fi

    if echo "$input_val" | grep -Eq '^[0-9]+$'; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local idx=1
            for item in $instance_list; do
                if [ "$idx" -eq "$input_val" ]; then
                    CURRENT_INSTANCE="$item"
                    break
                fi
                idx=$((idx + 1))
            done
            echo -e "${GREEN}操作焦点成功切为已有实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            echo -e "${RED}编号超出可用范围！${RESET}"
        fi
    else
        if is_valid_alias "$input_val"; then
            CURRENT_INSTANCE="$input_val"
            echo -e "${GREEN}成功锁定并创建新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET}${GREEN} (请在主菜单选择 [1] 下发部署服务)${RESET}"
        else
            echo -e "${RED}命名不规范，仅限使用英文字母、数字、中划线和下划线！${RESET}"
        fi
    fi
}

get_panel_status_info() {
    if rc-service "snellv6.${CURRENT_INSTANCE}" status 2>&1 | grep -q "started"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -x "$BASE_DIR/snell-server" ]; then
        panel_version=$("$BASE_DIR/snell-server" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n1)
        [ -z "$panel_version" ] && panel_version="v6.X 内核"
    else
        panel_version="${RED}未下载内核${RESET}"
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    if [ -f "$conf_file" ]; then
        # 提取等号后面的完整字符串（保留逗号及后面的 IPv6），只去掉空格
        panel_port=$(grep '^listen' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n')
    else
        panel_port="未创建节点配置"
    fi
}

# ── 主轮询路由中心 ────────────────────────────────────────────────────────────
while true; do
    get_panel_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}       ◈  Snell v6 多实例管理面板  ◈       ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标节点监听 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 安装当前实例${RESET}"
    echo -e "${GREEN} 2. 更新内核程序${RESET}"
    echo -e "${GREEN} 3. 卸载当前实例${RESET}"
    echo -e "${GREEN} 4. 修改当前实例${RESET}"
    echo -e "${GREEN} 5. 启动当前实例${RESET}"
    echo -e "${GREEN} 6. 停止当前实例${RESET}"
    echo -e "${GREEN} 7. 重启当前实例${RESET}"
    echo -e "${GREEN} 8. 当前实例日志${RESET}"
    echo -e "${GREEN} 9. 当前实例配置${RESET}"
    echo -e "${GREEN}10. 管理实例${RESET}      ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    choice=""
    echo -n -e "${GREEN}选择操作序号: ${RESET}"
    read -r choice
    case "$choice" in
        1) menu_install_instance "new" ; pause ;;
        2) 
            VER=$(get_latest_snell_version)
            download_and_extract_snell "$VER" && echo -e "${GREEN}[OK]二进制核心覆盖升级完毕，请视情况手动重启各运行中的实例。${RESET}" ; pause
            ;;
        3) menu_uninstall_instance ; pause ;;
        4) menu_install_instance "edit" ; pause ;;
        5) rc-service "snellv6.${CURRENT_INSTANCE}" start >/dev/null 2>&1 && echo -e "${GREEN}[OK]启动成功${RESET}"; pause ;;
        6) rc-service "snellv6.${CURRENT_INSTANCE}" stop >/dev/null 2>&1 && echo -e "${GREEN}[OK]停止成功${RESET}"; pause ;;
        7) rc-service "snellv6.${CURRENT_INSTANCE}" restart >/dev/null 2>&1 && echo -e "${GREEN}[OK]重启完毕${RESET}"; pause ;;
        8) 
            echo -e "${YELLOW}[信息] 正在查看当前实例最新运行日志输出 (按 Ctrl+C 退出):${RESET}"
            if [ -f "/var/log/snellv6_${CURRENT_INSTANCE}.log" ]; then
                tail -f -n 50 "/var/log/snellv6_${CURRENT_INSTANCE}.log"
            else
                echo -e "${YELLOW}该实例暂未产生任何活动日志。${RESET}"
                pause
            fi
            ;;
        9) print_instance_summary "$CURRENT_INSTANCE" ; pause ;;
        10) menu_switch_matrix ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[警告] 输入未知操作序号！${RESET}" ; sleep 0.5 ;;
    esac
done
