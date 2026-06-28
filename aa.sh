#!/usr/bin/env bash

# =============================================================================
#  Shadowsocks-Rust 智能多实例矩阵管理面板 (Alpine Linux / OpenRC 专属版)
#  协议标准: SS-2022 (2022-blake3-aes-256-gcm)
# =============================================================================

set -Eu

# ── 核心路径与全局隔离变量 ──────────────────────────────────────────────────
export TEMPLATE_NAME="ss-rust"
export BASE_DIR="/etc/${TEMPLATE_NAME}"
export BINARY_PATH="/usr/local/bin/ssserver"
export RUN_USER="ss-rust"
export RUN_GROUP="ss-rust"
export METHOD="2022-blake3-aes-256-gcm"
export KEY_BYTES=32

# 注册表文件：持久化记录活跃实例名字
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "SS")"

# ── 终端颜色定义 ────────────────────────────────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# 动态临时沙盒
TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ── GITHUB 代理加速源 ────────────────────────────────────────────────────────
GITHUB_PROXIES="DIRECT https://v6.gh-proxy.org/ https://gh-proxy.com/ https://hub.glowp.xyz/ https://proxy.vvvv.ee/ https://ghproxy.lvedong.eu.org/"

# ── 运行沙盒清理与安全退出 ──────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    exit $exit_code
}
trap cleanup EXIT INT TERM

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi


# ── 底层依赖精准检测与静默补全 (Alpine APK) ──────────────────────────────────
check_deps() {
    echo -e "${BLUE}[信息] 正在刷新 Alpine 软件源并检测底层组件...${RESET}"
    
    # 强制刷新本地索引，确保能找到 xz 和 gcompat
    apk update >/dev/null 2>&1
    
    # 补全关键解压与运行工具
    apk add wget tar xz openssl iproute2 coreutils gcompat grep sed awk >/dev/null 2>&1
    
    if ! command -v xz >/dev/null 2>&1; then
        echo -e "${RED}[错误] xz 依赖件安装失败！请检查机器网络或手动执行: apk update && apk add xz${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}[成功] 基础依赖与解压引擎检测就绪${RESET}"
}

# ── 核心安全组件 ────────────────────────────────────────────────────────────
create_user() {
    getent group "$RUN_GROUP" >/dev/null || addgroup -S "$RUN_GROUP"
    getent passwd "$RUN_USER" >/dev/null || adduser -S -D -H -G "$RUN_GROUP" -s /sbin/nologin "$RUN_USER"
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
random_key() { openssl rand -base64 "$KEY_BYTES" | tr -d '\n'; }
random_port() { shuf -i 2000-65000 -n 1; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -; }

validate_password() {
    local password="$1"
    if ! echo "$password" | base64 -d >/dev/null 2>&1; then
        echo -e "${RED}[错误] 密码并非合法的 Base64 编码格式${RESET}" >&2
        return 1
    fi
    local decoded_len
    decoded_len=$(echo "$password" | base64 -d 2>/dev/null | wc -c)
    if [[ "$decoded_len" -ne "$KEY_BYTES" ]]; then
        echo -e "${RED}[错误] SS-2022 对齐要求密码解密后必须恰好为 ${KEY_BYTES} 字节 (当前: ${decoded_len} 字节)${RESET}" >&2
        return 1
    fi
    return 0
}

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

detect_arch() {
    case "$(uname -m)" in
        x86_64)   echo "x86_64-unknown-linux-musl" ;;
        aarch64)  echo "aarch64-unknown-linux-musl" ;;
        *)
            echo -e "${RED}[错误] 不支持的系统架构: $(uname -m)${RESET}" >&2
            exit 1
            ;;
    esac
}

# ── 注册表核心控制模块 ────────────────────────────────────────────────────────
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
    local temp_reg="${TMP_DIR}/sync.env"
    touch "$temp_reg"
    for f in "${BASE_DIR}"/config_*.json; do
        [ -e "$f" ] || continue
        local name
        name=$(basename "$f" | sed 's/^config_//;s/\.json$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

# ── 核心文件下载引擎 ──────────────────────────────────────────────────────────
fetch_latest_version() {
    echo -e "${BLUE}[信息] 正在轮询检索 GitHub 官方 Shadowsocks-Rust 最新发行版...${RESET}"
    VERSION=""
    SELECTED_PROXY=""

    for proxy in $GITHUB_PROXIES; do
        local current_proxy=""
        if [ "$proxy" = "DIRECT" ]; then
            current_proxy=""
        else
            current_proxy="$proxy"
        fi

        local api_url="${current_proxy}https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null) || continue
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 | sed -E 's/^v//')
        
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="$tmp_ver"
            SELECTED_PROXY="$current_proxy"
            echo -e "${GREEN}[成功] 成功获取到最新版本: v${VERSION}${RESET}"
            break
        fi
    done

    if [ -z "$VERSION" ]; then
        VERSION="1.18.4" # 稳定兜底版
        SELECTED_PROXY=""
        echo -e "${YELLOW}[警告] 网络请求受阻，将降级采用稳定默认版本: v${VERSION}${RESET}"
    fi
}

download_bin_package() {
    local arch
    arch=$(detect_arch)
    fetch_latest_version
    local download_success=false

    local url_path="${SELECTED_PROXY}https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${arch}.tar.xz"
    echo -e "${BLUE}[信息] 正在推进核心资产包下载...${RESET}"
    echo -e "${BLUE}下载源: ${CYAN}${SELECTED_PROXY:-官方直连}${RESET}"
    
    if wget --timeout=15 --tries=3 --no-check-certificate -O "$TMP_DIR/ss.tar.xz" "$url_path"; then
        if [ -s "$TMP_DIR/ss.tar.xz" ]; then
            download_success=true
            cd "$TMP_DIR" && tar -xf ss.tar.xz
            echo -e "${GREEN}[成功] 资产包下载并解压成功！${RESET}"
        fi
    fi

    if [ "$download_success" = "false" ]; then
        echo -e "${RED}[错误] GitHub 镜像拉取资产失败，请检查机器网络状况。${RESET}" >&2
        exit 1
    fi
}

# ── 配置与 OpenRC 动态多服务分流核心写入 ──────────────────────────────────────
write_config() {
    local instance="$1" port="$2" password="$3" dns="$4"
    local conf_file="${BASE_DIR}/config_${instance}.json"
    
    mkdir -p "$BASE_DIR"
    local dns_str=$(echo "$dns" | tr -d ' ')
    local dns_json=$(echo "\"${dns_str//,/\",\"}\"")

    cat > "$conf_file" <<EOF
{
    "server": "::",
    "server_port": ${port},
    "password": "${password}",
    "method": "${METHOD}",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [${dns_json}],
    "_meta": { "alias": "${instance}" }
}
EOF
    chmod 600 "$conf_file"
    chown -R "${RUN_USER}:${RUN_GROUP}" "$BASE_DIR"
    register_instance "$instance"
}

write_openrc_matrix_script() {
    local instance="$1"
    local log_path="/var/log/ss-rust_${instance}.log"
    local init_dest="/etc/init.d/ss-rust.${instance}"

    # 预创建好专属于该实例的独立日志通道文件
    touch "$log_path"
    chown "${RUN_USER}:${RUN_GROUP}" "$log_path"

    # 写入 OpenRC 动态参数托管脚本
    cat > "$init_dest" <<EOF
#!/sbin/openrc-run

# 动态绑定当前 OpenRC 的分流服务后缀名
INSTANCE="\${RC_SVCNAME#ss-rust.}"
[ "\${RC_SVCNAME}" = "ss-rust" ] && INSTANCE="default"

name="ss-rust matrix (\${INSTANCE})"
command="${BINARY_PATH}"
command_args="-c ${BASE_DIR}/config_\${INSTANCE}.json"
command_user="${RUN_USER}:${RUN_GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/ss-rust_\${INSTANCE}.log"
error_log="/var/log/ss-rust_\${INSTANCE}.log"

depend() {
    need net
}
EOF
    chmod +x "$init_dest"
}

generate_share_links() {
    local instance="$1"
    local file="${BASE_DIR}/config_${instance}.json"
    [[ ! -f "$file" ]] && return 1
    
    local port password ip encoded display_ip hostname
    port=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$file")
    password=$(sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' "$file" | head -n1)
    ip=$(get_public_ip "auto")
    hostname=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "SS")
    encoded=$(echo -n "${METHOD}:${password}" | base64 | tr -d '\n\r ')

    display_ip="$ip"
    if [[ "$ip" == *":"* ]]; then display_ip="[$ip]"; fi

    cat > "${BASE_DIR}/link_${instance}_ss.txt" <<EOF
ss://${encoded}@${display_ip}:${port}#${hostname}-${instance}-SS2022
EOF

    cat > "${BASE_DIR}/link_${instance}_surge.txt" <<EOF
${hostname}-${instance}-SS2022 = ss, ${ip}, ${port}, encrypt-method=${METHOD}, password=${password}, tfo=true, udp-relay=true, ecn=true
EOF
}

print_instance_summary() {
    local instance="$1"
    local file="${BASE_DIR}/config_${instance}.json"
    if [ ! -f "$file" ]; then return; fi

    generate_share_links "$instance"

    local port_num pass_val dns_val
    port_num=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$file")
    pass_val=$(sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' "$file" | head -n1)

    echo -e "\n${GREEN}====== Shadowsocks 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN} 绑定外网 IP  :${RESET} $(get_public_ip "auto")"
    echo -e "${GREEN} 监听绑定端口 :${RESET} ${port_num}"
    echo -e "${GREEN} 预共享密钥   :${RESET} ${pass_val}"
    echo -e "${GREEN} 加密防护算法 :${RESET} ${METHOD}"
    echo -e "${GREEN} 独立配置文件 :${RESET} ${file}"
    echo "------------------------------------------------------------------------"
    if [[ -f "${BASE_DIR}/link_${instance}_ss.txt" ]]; then
        echo -e "${GREEN}[SS 2022 订阅链接] :${RESET}"
        echo -e "${YELLOW}$(cat "${BASE_DIR}/link_${instance}_ss.txt")${RESET}\n"
    fi
    if [[ -f "${BASE_DIR}/link_${instance}_surge.txt" ]]; then
        echo -e "${GREEN}[Surge 托管配置]   :${RESET}"
        echo -e "${YELLOW}$(cat "${BASE_DIR}/link_${instance}_surge.txt")${RESET}"
    fi
    echo ""
}

# ── 交互式菜单逻辑核心 ────────────────────────────────────────────────────────
menu_install_instance() {
    check_deps
    create_user
    
    local is_edit=false
    if [ "${1:-}" = "edit" ]; then is_edit=true; fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
    
    # 【💡 极其关键的一步】：无论新装还是修改，提前把核心基础目录准备好，杜绝写入 version.txt 时文件夹不存在的 Bug！
    mkdir -p "$BASE_DIR"

    if [ "$is_edit" = "true" ] && [ -f "$conf_file" ]; then
        echo -e "\n${GREEN}==== [💡 正在微调修改实例: ${CURRENT_INSTANCE} (直接回车保持原样)] ====${RESET}"
        OLD_PORT=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$conf_file")
        OLD_PASS=$(sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' "$conf_file" | head -n1)
        OLD_DNS=$(sed -n '/"nameserver":/,/\]/p' "$conf_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd "," -)
    else
        if [ -f "$conf_file" ]; then
            echo -e "${YELLOW}[警告] 检测到当前实例 [ ${CURRENT_INSTANCE} ] 已经存在。${RESET}"
            local confirm=""
            read -r -p "$(echo -e "${GREEN}是否强行完全覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
            [[ "$confirm" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
        OLD_PORT=$(random_port)
        while ! check_port_occupied "$OLD_PORT"; do OLD_PORT=$(random_port); done
        OLD_PASS=$(random_key)
        OLD_DNS=$(get_system_dns)
    fi

    # 1. 端口绑定引导
    local input_port="" opt_port=""
    while true; do
        read -r -p "$(echo -e "${GREEN}请输入服务端口 [默认: ${YELLOW}${OLD_PORT}${GREEN}]: ${RESET}")" input_port || true
        opt_port="${input_port:-$OLD_PORT}"
        if is_valid_port "$opt_port"; then
            if [ "$opt_port" != "${OLD_PORT}" ] || [ "$is_edit" = "false" ]; then
                if ! check_port_occupied "$opt_port"; then
                    echo -e "${RED}[错误] 端口 ${opt_port} 目前正被其他进程占用，请换个端口！${RESET}" >&2
                    continue
                fi
            fi
            break
        else
            echo -e "${RED}[错误] 端口无效，请输入 1-65535 之间的整数数值。${RESET}" >&2
        fi
    done

    # 2. 密码配置引导
    local input_pwd="" opt_pwd=""
    while true; do
        read -r -p "$(echo -e "${GREEN}请输入 Base64 密码 (32字节) [默认: ${YELLOW}${OLD_PASS}${GREEN}]: ${RESET}")" input_pwd || true
        opt_pwd="${input_pwd:-$OLD_PASS}"
        validate_password "$opt_pwd" && break
    done

    # 3. 内置上游 DNS 引导
    local input_dns="" opt_dns=""
    read -r -p "$(echo -e "${GREEN}请输入内部解析 DNS [默认: ${YELLOW}${OLD_DNS}${GREEN}]: ${RESET}")" input_dns || true
    opt_dns="${input_dns:-$OLD_DNS}"

    # 4. 执行文件落盘与启动逻辑
    if [ ! -f "$BINARY_PATH" ]; then
        download_bin_package
        install -m 755 "$TMP_DIR/ssserver" "$BINARY_PATH"
        echo "$VERSION" > "${BASE_DIR}/version.txt"
    else
        if [ ! -f "${BASE_DIR}/version.txt" ]; then
            echo "1.24.0" > "${BASE_DIR}/version.txt"
        fi
    fi

    write_config "$CURRENT_INSTANCE" "$opt_port" "$opt_pwd" "$opt_dns"
    write_openrc_matrix_script "$CURRENT_INSTANCE"

    echo -e "${BLUE}[信息] 正在通过 OpenRC 引擎安全拉起矩阵实例...${RESET}"
    rc-update add "ss-rust.${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    rc-service "ss-rust.${CURRENT_INSTANCE}" restart

    sleep 1
    if rc-service "ss-rust.${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}[成功] OpenRC 实例 [ ${CURRENT_INSTANCE} ] 矩阵上云成功！${RESET}"
        print_instance_summary "$CURRENT_INSTANCE"
    else
        echo -e "${RED}[错误] 实例部署完成，但拉起后遇到异常，请按菜单 8 查看日志排查。${RESET}" >&2
    fi
}

menu_uninstall_instance() {
    echo -e "${YELLOW}[警告] 该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立 OpenRC 服务。${RESET}"
    local confirm=""
    read -r -p "$(echo -e "${RED}确认完全抹除实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" confirm || true
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    rc-service "ss-rust.${CURRENT_INSTANCE}" stop >/dev/null 2>&1 || true
    rc-update del "ss-rust.${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    
    rm -f "/etc/init.d/ss-rust.${CURRENT_INSTANCE}"
    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
    rm -f "${BASE_DIR}/link_${CURRENT_INSTANCE}_ss.txt"
    rm -f "${BASE_DIR}/link_${CURRENT_INSTANCE}_surge.txt"
    rm -f "/var/log/ss-rust_${CURRENT_INSTANCE}.log"
    
    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}[成功] 实例 [ ${CURRENT_INSTANCE} ] 现场清理干净。${RESET}"

    if [ -d "$BASE_DIR" ] && [ -z "$(ls -A "$BASE_DIR" | grep 'config_')" ]; then
        echo -e "${BLUE}[信息] 检测到矩阵内所有实例已被排空，自动触发全局常驻组件垃圾回收机制...${RESET}"
        rm -f "$BINARY_PATH" "$REGISTRY_FILE"
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}[成功] 全系统干净卸载，基础常驻组件已全部解绑！${RESET}"
        CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "SS")"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [多开实例 OpenRC 矩阵管理中心] ====${RESET}"
    echo -e "当前聚焦的操作目标: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "目前持久化注册表内的独立实例列表:"

    sync_registry

    local instance_list=()
    local count=0

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local conf_file="${BASE_DIR}/config_${name}.json"
            [ -f "$conf_file" ] || continue

            ((count++))
            instance_list+=("$name")
            
            local port_num
            port_num=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$conf_file" || echo "未知")
            local status_str="${RED}已挂起${RESET}"
            rc-service "ss-rust.${name}" status 2>/dev/null | grep -q "started" && status_str="${GREEN}分流中${RESET}"
            
            echo -e " [ ${CYAN}${count}${RESET} ] -> ${YELLOW}${name}${RESET} [端口: ${port_num} | 状态: ${status_str}]"
        done < "$REGISTRY_FILE"
    fi

    if [ "$count" -eq 0 ]; then
        echo " (暂无任何多开实例，请直接输入新名称创建)"
    fi
    
    echo ""
    echo -e "👉 ${GREEN}输入现有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "👉 ${GREEN}或者直接输入一个【全新的英文名字】来新建多开实例${RESET}"
    local input_val=""
    read -r -p "请输入选择或名字: " input_val || true

    if [ -z "$input_val" ]; then return; fi

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local index=$((input_val - 1))
            CURRENT_INSTANCE="${instance_list[$index]}"
            echo -e "${GREEN}[成功] 操作焦点已成功切为编号 [ ${input_val} ] 的实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            echo -e "${YELLOW}[警告] 编号输入超出范围！保持原有聚焦。${RESET}"
        fi
    else
        if is_valid_alias "$input_val"; then
            CURRENT_INSTANCE="$input_val"
            echo -e "${GREEN}[成功] 已锁定新实例焦点为: ${YELLOW}${CURRENT_INSTANCE}${RESET} (请在主菜单按 1 完成实际创建部署)"
        else
            echo -e "${RED}[错误] 名字仅限英文字母/数字/下划线/中划线组合！${RESET}" >&2
        fi
    fi
}

get_panel_status_info() {
    if rc-service "ss-rust.${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "${BASE_DIR}/version.txt" ]; then
        panel_version="v$(cat "${BASE_DIR}/version.txt") (OpenRC 矩阵版)"
    else
        panel_version="${RED}未下载内核${RESET}"
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
    if [ -f "$conf_file" ]; then
        local p_num
        p_num=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' "$conf_file")
        panel_port="${p_num} (SS-2022)"
    else
        panel_port="未创建配置"
    fi
}

# ── 主轮询路由中心 ────────────────────────────────────────────────────────────
while true; do
    get_panel_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈ Shadowsocks-Rust OpenRC 矩阵多实例面板  ◈ ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例端口 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 安装当前实例${RESET}"
    echo -e "${GREEN} 2. 更新全局内核程序${RESET}"
    echo -e "${GREEN} 3. 卸载当前实例${RESET}"
    echo -e "${GREEN} 4. 修改当前实例配置${RESET}"
    echo -e "${GREEN} 5. 启动当前实例${RESET}"
    echo -e "${GREEN} 6. 停止当前实例${RESET}"
    echo -e "${GREEN} 7. 重启当前实例${RESET}"
    echo -e "${GREEN} 8. 查看当前实例滚动日志${RESET}"
    echo -e "${GREEN} 9. 查看当前实例节点配置${RESET}"
    echo -e "${GREEN}10. 管理节点矩阵矩阵${RESET}  ${YELLOW}← 添加 / 切换独立实例${RESET}"
    echo -e "${GREEN} 0. 退出管理台面${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    choice=""
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice || true
    case "$choice" in
        1) menu_install_instance "new" ;;
        2) 
            download_bin_package && install -m 755 "$TMP_DIR/ssserver" "$BINARY_PATH"
            echo "$VERSION" > "${BASE_DIR}/version.txt"
            echo -e "${GREEN}[成功] 二进制核心覆盖升级完毕，请视情况手动重启各实例。${RESET}" 
            ;;
        3) menu_uninstall_instance ;;
        4) menu_install_instance "edit" ;;
        5) rc-service "ss-rust.${CURRENT_INSTANCE}" start ;;
        6) rc-service "ss-rust.${CURRENT_INSTANCE}" stop ;;
        7) rc-service "ss-rust.${CURRENT_INSTANCE}" restart ;;
        8) 
            local current_log="/var/log/ss-rust_${CURRENT_INSTANCE}.log"
            if [ -f "$current_log" ]; then
                echo -e "${BLUE}[信息] 正在监听实例实时日志输出 (Ctrl+C 返回):${RESET}"
                (trap 'exit 0' INT; tail -n 50 -f "$current_log")
            else
                echo -e "${RED}[错误] 该实例目前尚未生成任何物理日志文件。${RESET}" >&2
            fi
            ;;
        9) print_instance_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_matrix ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[警告] 无效输入序号！${RESET}"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制面板...${RESET}")" || true
done
