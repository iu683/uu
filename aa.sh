#!/usr/bin/env sh

# ==============================================================================
#  next-socks5 多实例管理面板 (Alpine Linux OpenRC 专属)
# ==============================================================================

# ── 核心环境变量与全局隔离变量 ──────────────────────────────────────────────────
export REPO="ZingerLittleBee/next-socks5"
export TEMPLATE_NAME="next-socks5"
export BASE_DIR="/etc/${TEMPLATE_NAME}"
export INSTALL_BIN="/usr/local/bin/${TEMPLATE_NAME}"
export DATA_BASE_DIR="/var/lib/${TEMPLATE_NAME}"

# 注册表文件：持久化记录矩阵内所有活跃的实例名
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "socks")"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# ── GITHUB 代理加速源 ────────────────────────────────────────────────────────
GITHUB_PROXIES="DIRECT https://v6.gh-proxy.org/ https://ghfast.top/ https://gh-proxy.com/ https://hub.glowp.xyz/ https://proxy.vvvv.ee/ https://ghproxy.lvedong.eu.org/"

# ── 基础环境校验 ──────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
pause() { echo; echo -n -e "${GREEN}按回车键重新返回控制面板...${RESET}"; read -r _; }

# 验证 Alpine 身份
if [ ! -f /etc/alpine-release ]; then
    die "此脚本为 Alpine Linux 专属定制版，检测到当前系统非 Alpine！"
fi

# Alpine 依赖补全
REQUIRED_CMDS="curl tar sed gawk grep openssl"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo -e "${YELLOW}[INFO]检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复...${RESET}"
    apk update -q && apk add -q --no-cache $MISSING_CMDS >/dev/null 2>&1
fi

create_user() {
    local service_user="socks5"
    if ! getent group "$service_user" >/dev/null 2>&1; then
        addgroup -S "$service_user" 2>/dev/null
    fi
    if ! id "$service_user" >/dev/null 2>&1; then
        adduser -S -D -H -G "$service_user" -g "socks5 proxy user" -s /sbin/nologin "$service_user" 2>/dev/null
    fi
}

check_port_occupied() {
    local port="$1"
    if netstat -tulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        return 1  # 占用
    fi
    return 0      # 空闲
}

is_valid_alias() { echo "$1" | grep -qE '^[a-zA-Z0-9_-]+$'; }

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
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    touch "$REGISTRY_FILE"
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
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    touch "$REGISTRY_FILE"
    local temp_reg
    temp_reg=$(mktemp)
    for f in "${BASE_DIR}"/config_*.toml; do
        [ -e "$f" ] || continue
        local name
        name=$(basename "$f" | sed 's/^config_//;s/\.toml$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

# ── 💡 代理轮询获取内核 ───────────────────────────────────────────────────────
fetch_latest_version() {
    echo -e "${YELLOW}[INFO]正在轮询检索 GitHub 官方最新发行版...${RESET}"
    VERSION="" SELECTED_PROXY=""

    for proxy in $GITHUB_PROXIES; do
        if [ "$proxy" = "DIRECT" ]; then
            current_proxy=""
            echo -e "${GREEN}尝试直连请求 GitHub API...${RESET}"
        else
            current_proxy="$proxy"
            echo -e "${GREEN}尝试使用代理: ${YELLOW}${current_proxy}${RESET}"
        fi

        local api_url="${current_proxy}https://api.github.com/repos/${REPO}/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)

        if [ -n "$tmp_ver" ] && [ "$tmp_ver" != "null" ]; then
            VERSION="$tmp_ver"
            SELECTED_PROXY="$current_proxy"
            echo -e "${GREEN}成功获取到最新版本:${RESET} ${GREEN}${VERSION}${RESET}"
            break
        fi
    done

    if [ -z "$VERSION" ]; then
        VERSION="v0.4.0"
        SELECTED_PROXY=""
        echo -e "${GREEN}所有代理请求失败，将降级采用默认稳定版本: ${VERSION}${RESET}"
    fi
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    echo "$VERSION" > "${BASE_DIR}/.version" 2>/dev/null
}

download_and_extract() {
    local ARCH
    ARCH=$(uname -m)
    local TARGET=""
    case "$ARCH" in
        x86_64)  TARGET="x86_64-unknown-linux-musl" ;;
        aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    fetch_latest_version
    local ASSET="next-socks5-${TARGET}.tar.gz"
    local URL_TGZ="${SELECTED_PROXY}https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"

    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo -e "${GREEN}同步下载二进制核心资产包...${RESET}"
    wget --timeout=15 --tries=3 --no-check-certificate -O "$TMP/$ASSET" "$URL_TGZ" || die "下载资产包失败！"

    tar xzf "$TMP/$ASSET" -C "$TMP"
    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find "$TMP" -type f -name "next-socks5" | head -n 1)
    [ -n "$EXTRACTED_BIN" ] || die "在压缩包内未找到 next-socks5 主程序！"
    
    install -m 0755 -o root -g root "$EXTRACTED_BIN" "$INSTALL_BIN"
    echo -e "${GREEN}全局主引擎内核同步部署完成。${RESET}"
}

# ── 核心写入配置生成器 ────────────────────────────────────────────────────────
write_config() {
    local instance="$1" bind_ip="$2" bind_port="$3" username="$4" password="$5"
    local conf_file="${BASE_DIR}/config_${instance}.toml"
    
    cat <<EOF > "$conf_file"
listen = "${bind_ip}:${bind_port}"

[auth]
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$conf_file"
method = "password"
[[auth.users]]
username = "${username}"
password = "${password}"
EOF
    else
        cat <<EOF >> "$conf_file"
method = "none"
EOF
    fi

    cat <<EOF >> "$conf_file"

[timeouts]
connect_ms = 10000
tcp_idle_ms = 300000
udp_idle_ms = 60000
EOF
    
    
    local inst_data_dir="${DATA_BASE_DIR}/${instance}"
    if [ ! -d "$inst_data_dir" ]; then
        mkdir -p "$inst_data_dir"
    fi
    chmod 0750 "$inst_data_dir"
    chown -R socks5:socks5 "$inst_data_dir" 2>/dev/null || true
    
    register_instance "$instance"
}

write_openrc_base_template() {
    # 写入主模板骨架
    cat <<'EOF' > "/etc/init.d/next-socks5"
#!/sbin/openrc-run

# 安全获取实例副名，如果为主脚本直接运行则 fallback
INSTANCE_NAME="${RC_SVCNAME#next-socks5.}"
[ "$RC_SVCNAME" = "next-socks5" ] && INSTANCE_NAME="default"

description="next-socks5 SOCKS5 Server - Instance: ${INSTANCE_NAME}"

command="/usr/local/bin/next-socks5"
command_args="serve --config /etc/next-socks5/config_${INSTANCE_NAME}.toml --no-tui"
command_user="socks5:socks5"
directory="/var/lib/next-socks5/${INSTANCE_NAME}"

command_background="true"
pidfile="/run/next-socks5.${INSTANCE_NAME}.pid"
output_log="/var/log/next-socks5.${INSTANCE_NAME}.log"
error_log="/var/log/next-socks5.${INSTANCE_NAME}.err"

rc_ulimit="-n 65535"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 -o socks5:socks5 "/var/lib/next-socks5/${INSTANCE_NAME}"
    checkpath -f -m 0640 -o socks5:socks5 "/var/log/next-socks5.${INSTANCE_NAME}.log" "/var/log/next-socks5.${INSTANCE_NAME}.err"
}
EOF
    chmod +x "/etc/init.d/next-socks5"
}

print_node_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.toml"
    [ -f "$conf_file" ] || return

    local bind_port
    bind_port=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$conf_file")
    [ -z "$bind_port" ] && bind_port="1080"
    
    local auth_method
    auth_method=$(gawk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    
    local auth_user="" auth_pass=""
    if [ "$auth_method" = "password" ]; then
        auth_user=$(gawk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
        auth_pass=$(gawk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
    fi

    local ip
    ip=$(get_public_ip "auto")
    display_ip="$ip"
    if [[ "$ip" == *":"* ]]; then display_ip="[$ip]"; fi

    echo -e "\n${GREEN}====== 矩阵实例${RESET} ${YELLOW}[ ${instance} ]${RESET} ${GREEN}配置详情 ======${RESET}"
    echo -e "${GREEN} 实例名 (ID)   :${RESET} ${instance}"
    echo -e "${GREEN} 公网出口 IP   :${RESET} ${display_ip}"
    echo -e "${GREEN} 服务绑定端口  :${RESET} ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo -e "${GREEN} 用户名 (User) :${RESET} ${auth_user}"
        echo -e "${GREEN} 密码 (Pass)   :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN} 鉴权公开模式  :${RESET} ${YELLOW}无密码公开访问${RESET}"
    fi
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}====== 👉 通用客户端 Socks5 链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}socks://${auth_user}:${auth_pass}@${display_ip}:${bind_port}#next-${instance}${RESET}"
    else
        echo -e "${YELLOW}socks://${display_ip}:${bind_port}#next-${instance}${RESET}"
    fi
    
    echo -e "${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e "${YELLOW}https://t.me/socks?server=${display_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
    else
        echo -e "${YELLOW}https://t.me/socks?server=${display_ip}&port=${bind_port}${RESET}"
    fi
    echo ""
}

# ── 交互式多开矩阵核心逻辑 ────────────────────────────────────────────────────
menu_install_instance() {
    create_user
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    write_openrc_base_template

    local is_edit=false
    if [ "${1:-}" = "edit" ]; then is_edit=true; fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    local old_ip="::" old_port="" old_user="" old_pass=""

    if [ "$is_edit" = "true" ] && [ -f "$conf_file" ]; then
        echo -e "\n${GREEN}==== [正在修改实例参数: ${CURRENT_INSTANCE}] ====${RESET}"
        local current_bind
        current_bind=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        old_ip="${current_bind%%:*}" old_port="${current_bind##*:}"
        [ -z "$old_ip" ] && old_ip="::"
        
        local current_method
        current_method=$(gawk -F '=' '/^[[:space:]]*method[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        if [ "$current_method" = "password" ]; then
            old_user=$(gawk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
            old_pass=$(gawk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {match($2, /"[^"]*"/); if(RSTART){print substr($2, RSTART+1, RLENGTH-2)}else{gsub(/[ [:space:]]/,"",$2);print $2}}' "$conf_file")
        fi
    else
        if [ -f "$conf_file" ]; then
            echo -e "${YELLOW}[WARN]检测到该实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
            read -r -p "$(echo -e "${GREEN}是否强行完全覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
            [[ "$confirm" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新多开实例矩阵: ${CURRENT_INSTANCE}] ====${RESET}"
        old_port=$((RANDOM % 50001 + 10000))
        while ! check_port_occupied "$old_port"; do old_port=$((RANDOM % 50001 + 10000)); done
        old_user="user_$(openssl rand -hex 4)"
        old_pass="$(openssl rand -hex 10)"
    fi

    # 1. IP 引导
    echo -n -e "${GREEN}请输入监听 IP 地址 [当前: ${old_ip}]: ${RESET}"
    read -r input_ip
    local opt_ip="${input_ip:-$old_ip}"

    # 2. 端口引导
    local opt_port=""
    while true; do
        echo -n -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${old_port}${GREEN}]: ${RESET}"
        read -r input_port
        opt_port="${input_port:-$old_port}"
        
        if echo "$opt_port" | grep -qE '^[0-9]+$' && [ "$opt_port" -gt 0 ] && [ "$opt_port" -le 65535 ]; then
            if [ "$is_edit" = "true" ] && [ "$opt_port" = "$old_port" ]; then
                break
            fi
            if ! check_port_occupied "$opt_port"; then
                error "端口 ${opt_port} 正被系统其他程序占用，请重新更换！"
                continue
            fi
            break
        else
            warn "不合法的端口号，请输入 1-65535 之间的纯数字！"
        fi
    done

    # 3. 账户鉴权引导
    local opt_user="" local opt_pass=""
    echo -n -e "${GREEN}请输入用户名 [当前: ${old_user:-无密码/免密}, 输入 ${RED}none${GREEN} 设为免密]: ${RESET}"
    read -r input_user
    local select_user="${input_user:-$old_user}"

    if [ "$select_user" = "none" ] || [ -z "$select_user" ]; then
        opt_user="" opt_pass=""
    else
        opt_user="$select_user"
        echo -n -e "${GREEN}请输入账户密码 [当前: ${old_pass:-自动随机新密码}]: ${RESET}"
        read -r input_pass
        opt_pass="${input_pass:-$old_pass}"
        [ -z "$opt_pass" ] && opt_pass="$(openssl rand -hex 10)"
    fi

    # 4. 下载内核保底
    if [ ! -f "$INSTALL_BIN" ]; then
        echo -e "${YELLOW}[INFO]未在系统全局找到核心引擎，开始请求拉取下载...${RESET}"
        download_and_extract
    fi

    # 5. 写入配置与动态绑定 OpenRC 软链接
    write_config "$CURRENT_INSTANCE" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    
    local inst_service="/etc/init.d/next-socks5.${CURRENT_INSTANCE}"
    if [ ! -L "$inst_service" ] && [ ! -f "$inst_service" ]; then
        ln -s /etc/init.d/next-socks5 "$inst_service"
    fi

    rc-update add "next-socks5.${CURRENT_INSTANCE}" default >/dev/null 2>&1
    echo -e "${YELLOW}[INFO]拉起隔离子服务实例 [ next-socks5@${CURRENT_INSTANCE} ]...${RESET}"
    rc-service "next-socks5.${CURRENT_INSTANCE}" restart

    sleep 1
    if rc-service "next-socks5.${CURRENT_INSTANCE}" status >/dev/null 2>&1; then
        echo -e "${GREEN}[INFO]矩阵实例 [ ${CURRENT_INSTANCE} ] 启动成功并切入后台分流矩阵！${RESET}"
        print_node_summary "$CURRENT_INSTANCE"
    else
        echo -e "${RED}[INFO]实例下发完成，但 Systemd 响应拉起失败，请检查端口是否冲突或选择 [8] 查看实时日志。${RESET}"
    fi
}

menu_uninstall_instance() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    echo -n -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}"
    read -r confirm
    case "$confirm" in [Yy]) ;; *) return ;; esac

    rc-service "next-socks5.${CURRENT_INSTANCE}" stop >/dev/null 2>&1
    rc-update del "next-socks5.${CURRENT_INSTANCE}" default >/dev/null 2>&1
    
    rm -f "/etc/init.d/next-socks5.${CURRENT_INSTANCE}"
    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    rm -rf "${DATA_BASE_DIR}/${CURRENT_INSTANCE}"
    rm -f "/var/log/next-socks5.${CURRENT_INSTANCE}.log" "/var/log/next-socks5.${CURRENT_INSTANCE}.err"
    
    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}[OK]实例 [ ${CURRENT_INSTANCE} ] 现场清理干净。${RESET}"

    # 检测并进行常驻全局彻底自清理
    sync_registry
    if [ ! -s "$REGISTRY_FILE" ]; then
        echo -e "${YELLOW}[INFO]检测到矩阵内所有实例已被排空，自动触发全局常驻组件垃圾回收机制...${RESET}"
        rm -f /etc/init.d/next-socks5
        rm -f "$INSTALL_BIN"
        rm -rf "$BASE_DIR" "$DATA_BASE_DIR"
        deluser socks5 >/dev/null 2>&1
        echo -e "${GREEN}[OK]全系统干净卸载，基础常驻依赖与核心已全部解绑！${RESET}"
        CURRENT_INSTANCE="socks"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [多开实例 OpenRC 节点矩阵切换中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    sync_registry
    local count=0
    local instance_list=""

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.toml"
            [ -f "$c_file" ] || continue

            count=$((count + 1))
            # 存入空格分隔的列表用于索引
            instance_list="${instance_list} ${name}"
            
            local port_num
            port_num=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$c_file")
            
            local status_str="${RED}已停止${RESET}"
            if rc-service "next-socks5.${name}" status >/dev/null 2>&1; then
                status_str="${GREEN}运行中${RESET}"
            fi
            
            echo -e " ${CYAN}[ ${count} ] ->${GREEN} 实例名: ${YELLOW}${name}${RESET} ${GREEN}[绑定端口: ${port_num} | 运行状态: ${status_str}]${GREEN}"
        done < "$REGISTRY_FILE"
    fi

    if [ "$count" -eq 0 ]; then echo -e " ${YELLOW}(当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)${RESET}"; fi
    
    echo ""
    echo -e "${GREEN}👉 输入已有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文别名】来新建独立多开实例${RESET}"
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true

    if [ -z "$input_val" ]; then return; fi

    if echo "$input_val" | grep -qE '^[0-9]+$'; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            # 顺位截取
            local idx=1
            for name in $instance_list; do
                if [ "$idx" -eq "$input_val" ]; then
                    CURRENT_INSTANCE="$name"
                    echo -e "${GREEN}操作焦点成功切为已有实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
                    break
                fi
                idx=$((idx + 1))
            done
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
    if rc-service "next-socks5.${CURRENT_INSTANCE}" status >/dev/null 2>&1; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        if [ -f "${BASE_DIR}/.version" ]; then
            panel_version=$(cat "${BASE_DIR}/.version")
        else
            panel_version="v0.4.X 内核"
        fi
    else
        panel_version="${RED}未安装核心${RESET}"
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        panel_port=$(gawk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    else
        panel_port="实例未初始化"
    fi
}

# ── 主轮询路由控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_panel_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}      ◈ next-socks5 多实例管理面板 ◈       ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例监听 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心共享引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
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
    echo -e "${GREEN}10. 管理实例${RESET}  ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    echo -n -e "${GREEN}选择操作序号: ${RESET}"
    read -r choice || true
    
    case "$choice" in
        1) menu_install_instance "new"; pause ;;
        2) download_and_extract && echo -e "${GREEN}[OK]二进制核心覆盖升级完毕，请视情况手动重启各运行中的实例。${RESET}"; pause ;;
        3) menu_uninstall_instance; pause ;;
        4) menu_install_instance "edit"; pause ;;
        5) rc-service "next-socks5.${CURRENT_INSTANCE}" start && echo -e "${GREEN}[OK]启动成功${RESET}"; pause ;;
        6) rc-service "next-socks5.${CURRENT_INSTANCE}" stop && echo -e "${GREEN}[OK]停止成功${RESET}"; pause ;;
        7) rc-service "next-socks5.${CURRENT_INSTANCE}" restart && echo -e "${GREEN}[OK]重启完毕${RESET}"; pause ;;
        8) 
            log_f="/var/log/next-socks5.${CURRENT_INSTANCE}.log"
            if [ -f "$log_f" ]; then
                echo -e "${YELLOW}正在查看当前实例实时输出日志 (按 Ctrl+C 退出返回菜单):${RESET}\n"
                tail -n 50 -f "$log_f"
            else
                warn "该实例暂未开始运行，没有相应的日志文件记录。" ; pause
            fi
            ;;
        9) print_node_summary "$CURRENT_INSTANCE"; pause ;;
        10) menu_switch_matrix ;;
        0) clear; exit 0 ;;
        *) echo -e "${YELLOW}[警告] 输入了未知操作序号！${RESET}" ; sleep 0.5 ;;
    esac
done
