#!/usr/bin/env bash

# =============================================================================
#  Snell v6 Server 智能多实例矩阵管理面板 (Linux Systemd 专属强力修复版)
#  完美兼容: Surge Mac / iOS 客户端 (全面支持多实例隔离、IPv6 自动包裹)
# =============================================================================

set -Eu
set -o pipefail

# ── 核心路径与全局隔离变量 ──────────────────────────────────────────────────
export TEMPLATE_NAME="snellv6"
export BASE_DIR="/etc/${TEMPLATE_NAME}"
export LOG_FILE="/var/log/${TEMPLATE_NAME}_manager.log"
export SNELL_USER="snellv6"

# 注册表文件：持久化记录矩阵内所有活跃的实例名
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "snell")"

# ── 终端颜色定义 ────────────────────────────────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

if [ "$EUID" -ne 0 ]; then
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
    id -u "$SNELL_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin "$SNELL_USER"
}

check_port_occupied() {
    local port="$1"
    if ss -tulnH | awk '{print $5}' | grep -qE "[:.]${port}$"; then
        return 1  # 占用
    fi
    return 0      # 空闲
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }
is_valid_alias() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }
random_key() { openssl rand -base64 24 | tr -d '\n\r/=+' | head -c 20; }
random_port() { shuf -i 2000-65000 -n 1; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -; }

get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
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
        local name
        name=$(basename "$f" | sed 's/^config_//;s/\.conf$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

# ── 智能动态感知 Snell v6 版本 ──────────────────────────────────────────────
get_latest_snell_version() {
    local latest_version=""
    latest_version=$(curl -sL --connect-timeout 4 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" | \
        grep -oE 'v6\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n 1 2>/dev/null || echo "")
        
    if [[ -z "$latest_version" ]]; then
        latest_version="v6.0.0b4" 
    fi
    echo "$latest_version"
}

download_and_extract_snell() {
    local RAW_VERSION=$1
    local ARCH=$(uname -m)
    
    if ! command -v unzip &>/dev/null; then
        info "未检测到 unzip，正在为您自动补全组件..."
        if command -v apt &>/dev/null; then apt update && apt install -y unzip;
        elif command -v yum &>/dev/null; then yum install -y unzip;
        elif command -v apk &>/dev/null; then apk update && apk add unzip; fi
    fi

    local URL_ARCH
    case "$ARCH" in
        aarch64|arm64)              URL_ARCH="linux-aarch64" ;;
        armv7l|armhf|armv8l)        URL_ARCH="linux-armv7l" ;;
        x86_64|amd64)               URL_ARCH="linux-amd64" ;;
        i386|i686|x86)              URL_ARCH="linux-i386" ;;
        *) error "不支持的系统架构: ${ARCH}"; return 1 ;;
    esac

    local VERSION_WITHOUT_V="${RAW_VERSION#v}"
    local VERSION_WITH_V="v${VERSION_WITHOUT_V}"

    local URLS=(
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITH_V}-${URL_ARCH}.zip"
        "https://dl.nssurge.com/snell/snell-server-${VERSION_WITHOUT_V}-${URL_ARCH}.zip"
    )

    local success=false
    for url in "${URLS[@]}"; do
        info "正在尝试下载内核: ${url}"
        if wget --timeout=8 --tries=1 --no-check-certificate -O snell.zip "$url" 2>/dev/null; then
            success=true && break
        fi
    done

    if [ "$success" = false ]; then
        warn "动态获取的测试版路径可能已失效，使用标准保底渠道下载..."
        local FALLBACK_URL="https://dl.nssurge.com/snell/snell-server-v6.0.0b4-${URL_ARCH}.zip"
        wget --no-check-certificate -O snell.zip "$FALLBACK_URL" || { error "下载 Snell 核心引擎失败！"; return 1; }
    fi

    unzip -o snell.zip -d "$BASE_DIR"
    rm -f snell.zip
    chmod +x "$BASE_DIR/snell-server"
    ok "Snell 二进制核心解压成功！"
}

# ── 核心写入与 Surge 配置优雅生成 (修复版) ──────────────────────────────────
write_config() {
    local instance="$1" port="$2" psk="$3" mode="$4" listen_mode="$5" dns_pref="$6" obfs="$7" tfo="$8" dns="$9"
    local conf_file="${BASE_DIR}/config_${instance}.conf"
    
    mkdir -p "$BASE_DIR"

    # 【核心重构修复点】：动态根据新输入的 port 重新渲染 listen 字段，防范旧配置文件脏换行符污染
    local real_listen=""
    case "$listen_mode" in
        *"0.0.0.0"*) real_listen="0.0.0.0:${port}" ;;
        *"[::]"*)    real_listen="[::]:${port}" ;;
        *)           real_listen="0.0.0.0:${port},[::]:${port}" ;;
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
    chown -R "$SNELL_USER":"$SNELL_USER" "$BASE_DIR" 2>/dev/null || true
    register_instance "$instance"

    local ip=$(get_public_ip "auto")
    local display_ip="$ip"
    if [[ "$ip" == *":"* ]]; then display_ip="[$ip]"; fi
    local hostname=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "SnellV6")

    cat > "${BASE_DIR}/link_${instance}.txt" <<EOF
${hostname}-${instance}-SnellV6 = snell, ${display_ip}, ${port}, psk=${psk}, version=6, mode=${mode}, tfo=${tfo}, reuse=true, ecn=true
EOF
}

print_instance_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.conf"
    [[ ! -f "$conf_file" ]] && return

    echo -e "\n${GREEN}====== Snell v6 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN} 绑定监听 (Listen) :${RESET} $(grep '^listen' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} 密钥 (PSK)        :${RESET} $(grep '^psk' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} 工作模式 (Mode)   :${RESET} $(grep '^mode' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo -e "${GREEN} Fast Open (TFO)   :${RESET} $(grep '^tfo' "$conf_file" | awk -F'=[ ]*' '{print $2}')"
    echo "------------------------------------------------------------------------"
    if [[ -f "${BASE_DIR}/link_${instance}.txt" ]]; then
        echo -e "${GREEN}[Surge 节点配置托管文本] :${RESET}"
        echo -e "${YELLOW}$(cat "${BASE_DIR}/link_${instance}.txt")${RESET}\n"
    fi
}

# ── 交互式多开逻辑 (修复版) ──────────────────────────────────────────────────
menu_install_instance() {
    create_user
    mkdir -p "$BASE_DIR"

    local is_edit=false
    if [ "${1:-}" = "edit" ]; then is_edit=true; fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    
    local old_port old_key old_mode old_listen old_dns_pref old_obfs old_tfo old_dns
    if [ "$is_edit" = "true" ] && [ -f "$conf_file" ]; then
        echo -e "\n${GREEN}==== [正在精细修改实例: ${CURRENT_INSTANCE}] ====${RESET}"
        
        # 【核心修复点】：添加 || true 阻断 set -eu 的进程强制终止，全面追加清洗规则
        old_listen=$(grep '^listen[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_port=$(echo "$old_listen" | awk -F: '{print $NF}' | cut -d',' -f1 || echo "")
        old_key=$(grep '^psk[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_mode=$(grep '^mode[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_obfs=$(grep '^obfs[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_tfo=$(grep '^tfo[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_dns=$(grep -E '^dns[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        old_dns_pref=$(grep '^dns-ip-preference[ ]*=' "$conf_file" | awk -F'=[ ]*' '{print $2}' | tr -d '\r\n ' || echo "")
        
        # 空变量精准保底兜底
        [[ -z "$old_port" ]] && old_port="61234"
        [[ -z "$old_key" ]] && old_key=$(random_key)
        [[ -z "$old_mode" ]] && old_mode="default"
        [[ -z "$old_obfs" ]] && old_obfs="off"
        [[ -z "$old_tfo" ]] && old_tfo="true"
        [[ -z "$old_dns" ]] && old_dns="8.8.8.8,8.8.4.4"
        [[ -z "$old_dns_pref" ]] && old_dns_pref="default"
    else
        if [ -f "$conf_file" ]; then
            warn "检测到该实例 [ ${CURRENT_INSTANCE} ] 已创建过配置。"
            local confirm=""
            read -r -p "是否强行完全重置此节点配置？[y/N]: " confirm
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
        [[ -z "$old_dns" ]] && old_dns="1.1.1.1,8.8.8.8"
        old_dns_pref="default"
    fi

    # 1. 端口引导
    local input_port="" opt_port=""
    while true; do
        read -r -p "$(echo -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${old_port}${GREEN}]: ${RESET}")" input_port
        opt_port="${input_port:-$old_port}"
        if is_valid_port "$opt_port"; then
            if [ "$opt_port" != "$old_port" ] || [ "$is_edit" = "false" ]; then
                if ! check_port_occupied "$opt_port"; then
                    error "端口 ${opt_port} 正被占用，请换个端口！"
                    continue
                fi
            fi
            break
        else
            error "端口无效，请输入 1-65535 整数。"
        fi
    done

    # 2. 密钥引导
    local input_key="" opt_key=""
    read -r -p "$(echo -e "${GREEN}请输入 PSK 密钥 [当前: ${YELLOW}${old_key}${GREEN}]: ${RESET}")" input_key
    opt_key="${input_key:-$old_key}"

    # 3. 混淆加密模式
    echo -e "${YELLOW}请选择 Snell 工作模式 (mode):${RESET}"
    echo "1. default     (流量混淆 + AES 加密)"
    echo "2. unshaped    (禁用混淆，仅加密。吞吐增高，等同于 v3)"
    echo "3. unsafe-raw  (纯明文传输模式：禁用加密混淆)"
    local choice_mode="" opt_mode="$old_mode"
    read -r -p "请选择 (直接回车保持当前): " choice_mode
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
    read -r -p "请选择 (直接回车保持默认/当前): " choice_listen
    case "$choice_listen" in
        2) opt_listen="0.0.0.0" ;;
        3) opt_listen="[::]" ;;
        1) opt_listen="dual" ;;
        *) opt_listen=${old_listen} ;;
    esac

    # 5. 家族优先级
    echo -e "${YELLOW}请选择 DNS 解析家族优先级 (dns-ip-preference):${RESET}"
    echo "1. default     2. prefer-ipv4     3. prefer-ipv6     4. ipv4-only     5. ipv6-only"
    local choice_pref="" opt_pref="$old_dns_pref"
    read -r -p "请选择 (回车保持): " choice_pref
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
    read -r -p "请选择 (回车保持): " choice_obfs
    case "$choice_obfs" in
        1) opt_obfs="tls" ;;
        2) opt_obfs="http" ;;
        3) opt_obfs="off" ;;
    esac

    # 7. TFO
    local choice_tfo="" opt_tfo="$old_tfo"
    read -r -p "$(echo -e "${GREEN}是否开启 TCP Fast Open？(1.开启 2.关闭) [当前: ${old_tfo}]: ${RESET}")" choice_tfo
    [[ "$choice_tfo" == "1" ]] && opt_tfo="true"
    [[ "$choice_tfo" == "2" ]] && opt_tfo="false"

    # 8. DNS
    local input_dns="" opt_dns=""
    read -r -p "$(echo -e "${GREEN}请输入上游解析 DNS [当前: ${YELLOW}${old_dns}${GREEN}]: ${RESET}")" input_dns
    opt_dns="${input_dns:-$old_dns}"

    # 下发安装
    if [ ! -f "$BASE_DIR/snell-server" ]; then
        info "正在检测并部署 Snell 核心运行时..."
        local VER=$(get_latest_snell_version)
        download_and_extract_snell "$VER"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_port" "$opt_key" "$opt_mode" "$opt_listen" "$opt_pref" "$opt_obfs" "$opt_tfo" "$opt_dns"
    write_systemd_template

    info "正在通知 Systemd 安全引擎接管并启动新服务实例..."
    systemctl daemon-reload
    systemctl enable "snellv6@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl restart "snellv6@${CURRENT_INSTANCE}"

    sleep 1
    if systemctl is-active --quiet "snellv6@${CURRENT_INSTANCE}"; then
        ok "实例 [ ${CURRENT_INSTANCE} ] 多开分流矩阵启动成功并已成功应用！"
        print_instance_summary "$CURRENT_INSTANCE"
    else
        error "实例配置下发完成，但拉起失败。请按菜单选项 8 查看服务系统错误日志。"
    fi
}

write_systemd_template() {
    cat > /etc/systemd/system/snellv6@.service <<EOF
[Unit]
Description=Snell v6 Dynamic Server Matrix Node (%i)
After=network.target

[Service]
Type=simple
ExecStart=${BASE_DIR}/snell-server -c ${BASE_DIR}/config_%i.conf
Restart=on-failure
User=${SNELL_USER}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

menu_uninstall_instance() {
    warn "该操作将直接熔断并销毁清洗当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立子服务。"
    local confirm=""
    read -r -p "确定完全移除此实例？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    systemctl stop "snellv6@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "snellv6@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    
    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    rm -f "${BASE_DIR}/link_${CURRENT_INSTANCE}.txt"
    unregister_instance "$CURRENT_INSTANCE"
    ok "实例 [ ${CURRENT_INSTANCE} ] 现场清洗干净。"

    if [ -d "$BASE_DIR" ] && [ -z "$(ls -A "$BASE_DIR" | grep 'config_')" ]; then
        info "检测到矩阵内已无任何子实例，自动启动全局常驻清理程序..."
        rm -f /etc/systemd/system/snellv6@.service
        systemctl daemon-reload
        rm -rf "$BASE_DIR"
        ok "全系统卸载干净，基础常驻组件已彻底清除。"
        CURRENT_INSTANCE="snell"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [多开实例 Systemd 节点矩阵管理中心] ====${RESET}"
    echo -e "当前聚焦的操作目标: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "目前持久化注册表内的独立实例列表:"

    sync_registry
    local instance_list=() count=0

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.conf"
            [ -f "$c_file" ] || continue

            ((count++))
            instance_list+=("$name")
            
            local port_num=$(grep '^listen' "$c_file" | awk -F: '{print $NF}' | cut -d',' -f1)
            local status_str="${RED}已挂起${RESET}"
            systemctl is-active --quiet "snellv6@${name}" && status_str="${GREEN}分流中${RESET}"
            
            echo -e " [ ${CYAN}${count}${RESET} ] -> ${YELLOW}${name}${RESET} [分配端口: ${port_num} | 核心状态: ${status_str}]"
        done < "$REGISTRY_FILE"
    fi

    [[ "$count" -eq 0 ]] && echo " (矩阵内空空如也，请直接输入新名称新建多开节点)"
    
    echo ""
    echo -e "👉 ${GREEN}输入已有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "👉 ${GREEN}或者直接输入一个【全新的英文名字】来新建多开实例${RESET}"
    local input_val=""
    read -r -p "请输入选择或新实例名字: " input_val

    if [ -z "$input_val" ]; then return; fi

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local index=$((input_val - 1))
            CURRENT_INSTANCE="${instance_list[$index]}"
            ok "操作焦点已成功切为实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            warn "编号超出可用范围！"
        fi
    else
        if is_valid_alias "$input_val"; then
            CURRENT_INSTANCE="$input_val"
            ok "已成功锁定新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET} (请在主菜单按 1 完成实际下发部署)"
        else
            error "命名仅限英文字母/数字/下划线组合！"
        fi
    fi
}

get_panel_status_info() {
    if systemctl is-active --quiet "snellv6@${CURRENT_INSTANCE}"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -x "$BASE_DIR/snell-server" ]; then
        panel_version=$("$BASE_DIR/snell-server" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -n1)
        [[ -z "$panel_version" ]] && panel_version="v6.X 内核"
    else
        panel_version="${RED}未下载内核${RESET}"
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.conf"
    if [ -f "$conf_file" ]; then
        panel_port=$(grep '^listen' "$conf_file" | awk -F'=[ ]*' '{print $2}')
    else
        panel_port="未创建节点配置"
    fi
}

# ── 主轮询路由中心 ────────────────────────────────────────────────────────────
while true; do
    get_panel_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈  Snell v6 Systemd 矩阵多实例管理面板   ◈ ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标节点监听 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 安装当前焦点实例${RESET}"
    echo -e "${GREEN} 2. 更新全局内核程序${RESET}"
    echo -e "${GREEN} 3. 卸载当前焦点实例${RESET}"
    echo -e "${GREEN} 4. 修改当前焦点实例配置${RESET}"
    echo -e "${GREEN} 5. 启动当前焦点实例${RESET}"
    echo -e "${GREEN} 6. 停止当前焦点实例${RESET}"
    echo -e "${GREEN} 7. 重启当前焦点实例${RESET}"
    echo -e "${GREEN} 8. 查看当前实例滚动日志 (Journald)${RESET}"
    echo -e "${GREEN} 9. 查看当前实例 Surge 配置单行${RESET}"
    echo -e "${GREEN}10. 管理节点矩阵矩阵${RESET}  ${YELLOW}← 添加 / 切换独立实例${RESET}"
    echo -e "${GREEN} 0. 退出管理台面${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    choice=""
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice || true
    case "$choice" in
        1) menu_install_instance "new" ; pause ;;
        2) 
            VER=$(get_latest_snell_version)
            download_and_extract_snell "$VER" && ok "内核升级完毕，请按 7 重启各实例生效。" ; pause
            ;;
        3) menu_uninstall_instance ; pause ;;
        4) menu_install_instance "edit" ; pause ;;
        5) systemctl start "snellv6@${CURRENT_INSTANCE}" ; pause ;;
        6) systemctl stop "snellv6@${CURRENT_INSTANCE}" ; pause ;;
        7) systemctl restart "snellv6@${CURRENT_INSTANCE}" ; pause ;;
        8) 
            echo -e "${BLUE}[信息] 正在调用 Journald 捕获实时日志输出 (Ctrl+C 返回菜单):${RESET}"
            journalctl -u "snellv6@${CURRENT_INSTANCE}" -f -n 50
            ;;
        9) print_instance_summary "$CURRENT_INSTANCE" ; pause ;;
        10) menu_switch_matrix ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[警告] 输入未知操作序号！${RESET}" ; sleep 0.5 ;;
    esac
done
