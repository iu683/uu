#!/usr/bin/sh

# =============================================================================
#  MicaProxy Alpine 专属多实例管理面板
# =============================================================================

export REPO="judy-gotv/Rust-SOCKS5-HTTP"
export BIN_PATH="/opt/MicaProxy/MicaProxy"
export INSTANCE_DIR="/etc/MicaProxy"
export DATA_DIR="/var/lib/micaproxy"
export LOG_DIR="/opt/MicaProxy/log"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname)"

export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

GITHUB_PROXIES=(
    ""
    "https://gh-proxy.com/"
    "https://proxy.vvvv.ee/"
    "https://v6.gh-proxy.org/"
    "https://ghproxy.lvedong.eu.org/"
    "https://hub.glowp.xyz/"
)

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# ── ⚡ 优化：按需依赖检查 ─────────────────────────────────────────────────────
REQUIRED_CMDS="sed grep awk openssl wget"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then 
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必备组件，正在为您初始化 Alpine 环境..."
    apk update -q
    apk add -q openssl wget sed grep gawk
    ok "环境初始化成功！"
fi

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -T 3 --no-check-certificate "$url" 2>/dev/null) && [ -n "$ip" ] && [ -z "$(echo "$ip" | grep ':')" ] && echo "$ip" && return 0
    done
    echo "127.0.0.1"
}

detect_target() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="micaproxy-linux-amd64" ;;
        aarch64) TARGET="micaproxy-linux-arm64" ;;
        armv7l)  TARGET="micaproxy-linux-armv7" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac
}

fetch_latest_version() {
    info "正在轮询获取 MicaProxy 最新 Release 版本号..."
    VERSION=""
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/${REPO}/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null)
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        if [ -n "$tmp_ver" ] && [ "$tmp_ver" != "null" ]; then
            VERSION="$tmp_ver"
            ok "成功获取到最新版本: ${GREEN}${VERSION}${RESET}"
            break
        fi
    done
    if [ -z "$VERSION" ]; then
        VERSION="v3.0.6"
        warn "降级采用稳定默认版本: ${VERSION}"
    fi
}

download_bin() {
    detect_target
    fetch_latest_version
    TMP_DIR="$(mktemp -d)"
    local download_success=false
    
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local url_bin="${proxy}https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}"
        info "正在尝试通过镜像源 [ ${CYAN}${proxy:-官方直连}${RESET} ] 下载资产包..."
        if wget -q --timeout=8 --tries=1 --no-check-certificate -O "$TMP_DIR/MicaProxy" "$url_bin"; then
            if [ -s "$TMP_DIR/MicaProxy" ]; then
                download_success=true
                ok "核心包通过 wget 同步下载完成！"
                break
            fi
        fi
        warn "当前源下载失败，正在为您自动切换下一个备用源..."
    done

    if [ "$download_success" = "false" ]; then
        rm -rf "$TMP_DIR"
        die "所有 GitHub 镜像代理源及官方通道均尝试失败，请检查网络后重试！"
    fi
    export TARGET_BIN_PATH="$TMP_DIR/MicaProxy"
}

write_openrc_service() {
    local rc_file="/etc/init.d/micaproxy"
    cat > "$rc_file" << 'EOF'
#!/sbin/openrc-run

description="MicaProxy Multi-instance Service"
INSTANCE="${RC_SVCNAME#micaproxy.}"

if [ "$RC_SVCNAME" = "micaproxy" ]; then
    INSTANCE="$(hostname)"
fi

CONF_FILE="/etc/MicaProxy/${INSTANCE}.toml"
LOG_FILE="/opt/MicaProxy/log/${INSTANCE}.log"

command="/opt/MicaProxy/MicaProxy"
command_args="-c ${CONF_FILE}"
command_background="yes"
pidfile="/run/micaproxy.${INSTANCE}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

# 解除 Alpine 默认限制
rc_ulimit="-n 65535"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "${CONF_FILE}" ]; then
        eerror "Configuration file ${CONF_FILE} missing!"
        return 1
    fi
    checkpath -d -m 0755 -o root:root /opt/MicaProxy/log
}
EOF
    chmod 0755 "$rc_file"
}

init_environment() {
    mkdir -p /opt/MicaProxy
    mkdir -p "$LOG_DIR"
    mkdir -p "$INSTANCE_DIR"
    mkdir -p "$DATA_DIR"
}

write_config() {
    local instance="$1" local proto="$2" local bind_ip="$3" local bind_port="$4" local username="$5" local password="$6" local outbound_type="$7"
    local conf_file="${INSTANCE_DIR}/${instance}.toml"
    
    if [ -z "$(echo "$bind_ip" | grep '\[')" ] && [ -n "$(echo "$bind_ip" | grep ':')" ]; then
        bind_ip="[${bind_ip}]"
    fi

    [ -z "$outbound_type" ] && outbound_type="default"

    cat <<EOF > "$conf_file"
[[outbounds]]
name = "${outbound_type}-outbound"
type = "${outbound_type}"

[[listeners]]
name = "${instance}-listener"
listen = "${bind_ip}:${bind_port}"
protocol = "${proto}"
outbound = "${outbound_type}-outbound"
EOF

    if [ -n "$username" ] && [ -n "$password" ]; then
        cat <<EOF >> "$conf_file"
username = "${username}"
password = "${password}"
EOF
    fi

    if [ "$proto" = "socks5" ]; then
        cat <<EOF >> "$conf_file"

[socks5]
enabled = true
udp_enabled = true
udp_idle_timeout_secs = 120
udp_buffer_bytes = 8192
EOF
    fi

    cat <<EOF >> "$conf_file"

[runtime]
driver = "epoll"
EOF
    chmod 0644 "$conf_file"
}

print_node_summary() {
    local instance="$1"
    local conf_file="${INSTANCE_DIR}/${instance}.toml"
    if [ ! -f "$conf_file" ]; then return; fi

    local proto
    proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$proto" ] && proto="socks5"

    local bind_port
    bind_port=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); split($2, a, ":"); print a[length(a)]}' "$conf_file")
    
    local auth_user
    auth_user=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | tr -d '"')
    local auth_pass
    auth_pass=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | tr -d '"')

    local public_ip
    public_ip=$(get_public_ip)

    echo -e "\n${GREEN}====== MicaProxy 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${CYAN}${proto^^}${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} ${public_ip}"
    echo -e "${GREEN}监听端口     :${RESET} ${bind_port}"
    if [ -n "$auth_user" ] && [ "$auth_user" != "none" ]; then
        echo -e "${GREEN}用户名       :${RESET} ${auth_user}"
        echo -e "${GREEN}密码         :${RESET} ${auth_pass}"
    else
        echo -e "${GREEN}鉴权模式     :${RESET} ${YELLOW}免密模式${RESET}"
    fi
    echo -e "${GREEN}配置文件路径 :${RESET} ${conf_file}"
    
    echo -e "${GREEN}====== 👉 客户端通用格式连接 ======${RESET}"
    if [ "$proto" = "socks5" ]; then
        if [ -n "$auth_user" ] && [ "$auth_user" != "none" ]; then
            echo -e "${YELLOW}socks5://${auth_user}:${auth_pass}@${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
            echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}&user=${auth_user}&pass=${auth_pass}${RESET}"
        else
            echo -e "${YELLOW}socks5://${public_ip}:${bind_port}#${instance}${RESET}"
            echo -e "\n${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
            echo -e "${YELLOW}https://t.me/socks?server=${public_ip}&port=${bind_port}${RESET}"
        fi
    elif [ "$proto" = "http" ]; then
        if [ -n "$auth_user" ] && [ "$auth_user" != "none" ]; then
            echo -e "${YELLOW}http://${auth_user}:${auth_pass}@${public_ip}:${bind_port}${RESET}"
        else
            echo -e "${YELLOW}http://${public_ip}:${bind_port}${RESET}"
        fi
    fi
    echo ""
}

get_status_info() {
    if [ -L "/etc/init.d/micaproxy.${CURRENT_INSTANCE}" ] || [ -f "/etc/init.d/micaproxy.${CURRENT_INSTANCE}" ]; then
        if rc-service "micaproxy.${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
            panel_status="${GREEN}运行中${RESET}"
        else
            panel_status="${RED}未运行${RESET}"
        fi
    else
        panel_status="${RED}未托管服务${RESET}"
    fi

    if [ -f "$BIN_PATH" ]; then
        local real_ver=$($BIN_PATH --version 2>/dev/null | head -n 1 | awk '{print $2}')
        [ -z "$real_ver" ] && real_ver=$($BIN_PATH -v 2>/dev/null | head -n 1)
        panel_version="${real_ver:-v3.x}"
    else
        panel_version="${RED}未下载核心${RESET}"
    fi

    local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    if [ -f "$conf_file" ]; then
        local proto
        proto=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        local p_num=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
        panel_port="${p_num} (${proto^^})"
    else
        panel_port="未创建配置"
    fi
}

parse_existing_config() {
    local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    if [ ! -f "$conf_file" ]; then return 1; fi

    OLD_PROTO=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    [ -z "$OLD_PROTO" ] && OLD_PROTO="socks5"

    local raw_listen
    raw_listen=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file")
    OLD_PORT=$(echo "$raw_listen" | awk -F ':' '{print $NF}')
    OLD_IP=$(echo "$raw_listen" | sed "s/:${OLD_PORT}$//g" | tr -d '[]')

    OLD_USER=$(awk -F '=' '/^[[:space:]]*username[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | tr -d '"')
    OLD_PASS=$(awk -F '=' '/^[[:space:]]*password[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | tr -d '"')
    [ -z "$OLD_USER" ] && OLD_USER="none"

    OLD_OUTBOUND=$(awk -F '=' '/^[[:space:]]*type[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$conf_file" | head -n 1)
    [ -z "$OLD_OUTBOUND" ] && OLD_OUTBOUND="default"
    return 0
}

menu_switch_instance() {
    echo -e "\n${GREEN}==== [多开实例矩阵管理中心] ====${RESET}"
    echo -e "当前聚焦的操作目标: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "目前存储于 ${INSTANCE_DIR} 内的独立实例列表:"

    local files="${INSTANCE_DIR}/*.toml"
    local count=0
    
    for f in $files; do
        [ -e "$f" ] || continue
        count=$((count + 1))
        local name=$(basename "$f" .toml)
        local proto_type=$(awk -F '=' '/^[[:space:]]*protocol[[:space:]]*=/ {gsub(/[ "[:space:]]/, "", $2); print $2}' "$f")
        local status_str="${RED}已挂起${RESET}"
        rc-service "micaproxy.${name}" status 2>/dev/null | grep -q "started" && status_str="${GREEN}分流中${RESET}"
        echo -e " [ ${CYAN}${count}${RESET} ] -> ${YELLOW}${name}${RESET} [协议: ${proto_type^^} | 状态: ${status_str}]"
    done

    if [ "$count" -eq 0 ]; then
        echo " (暂无任何多开实例，请直接输入新名称创建)"
    fi
    echo ""
    read -r -p "请输入要切换的[现有数字编号]或[直接输入全新英文名]: " input_val
    if [ -z "$input_val" ]; then return; fi

    if [ "$input_val" -eq "$input_val" ] 2>/dev/null; then
        local idx=0
        for f in $files; do
            [ -e "$f" ] || continue
            idx=$((idx + 1))
            if [ "$idx" -eq "$input_val" ]; then
                CURRENT_INSTANCE=$(basename "$f" .toml)
                ok "操作焦点已成功切为: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
                return
            fi
        done
        warn "编号不存在，未做任何变更。"
    else
        CURRENT_INSTANCE="$input_val"
        ok "操作焦点锁定新实例名: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    fi
}

menu_install() {
    init_environment
    local is_edit=false
    if [ "$1" = "edit" ]; then is_edit=true; fi

    if [ "$is_edit" = "true" ]; then
        if ! parse_existing_config; then
            die "未检测到实例 [ ${CURRENT_INSTANCE} ] 的旧配置，无法执行微调！"
        fi
        echo -e "\n${GREEN}==== [💡 正在微调修改实例: ${CURRENT_INSTANCE} (直接回车保持原样)] ====${RESET}"
    else
        local conf_file="${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
        if [ -f "$conf_file" ]; then
            warn "实例 [ ${CURRENT_INSTANCE} ] 已经存在对应配置文件。"
            read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res
            case "$res" in [Yy]*) ;; *) return ;; esac
        fi
        echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
        
        # ⚡ 纯正 Alpine 原生随机数发生器生成账号密码和可用随机端口
        local rand_user="user_$(openssl rand -hex 3)"
        local rand_pass="$(openssl rand -hex 6)"
        local rand_port="$(( (rand_seed = rand_seed + 1) * 37 % 45000 + 15000 ))"

        OLD_PROTO="socks5" OLD_IP="0.0.0.0" OLD_PORT="$rand_port" OLD_USER="$rand_user" OLD_PASS="$rand_pass" OLD_OUTBOUND="default"
    fi

    if [ "$is_edit" = "true" ]; then
        echo -e "当前协议类型: ${CYAN}${OLD_PROTO^^}${RESET} (1. SOCKS5 | 2. HTTP)"
        read -r -p "请输入新序号 [直接回车不修改]: " proto_choice
    else
        echo "1. SOCKS5 代理模式 (默认，附带完整 UDP 转发能力)"
        echo "2. HTTP 传输代理模式"
        read -r -p "选择形态序号 [1-2]: " proto_choice
    fi
    local opt_proto="$OLD_PROTO"
    if [ "$proto_choice" = "1" ]; then opt_proto="socks5"; elif [ "$proto_choice" = "2" ]; then opt_proto="http"; fi

    read -r -p "$(echo -e "${GREEN}请输入监听网卡 IP [当前: ${YELLOW}${OLD_IP}${GREEN} | 回车不改]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$OLD_IP}"

    read -r -p "$(echo -e "${GREEN}请输入服务端口 [当前: ${YELLOW}${OLD_PORT}${GREEN} | 回车不改]: ${RESET}")" input_port
    local opt_port="${input_port:-$OLD_PORT}"
    
    local opt_user="" local opt_pass=""
    # ⚡ 交互升级：中括号显示当前旧值或默认随机生成的账号
    read -r -p "$(echo -e "${GREEN}配置连接账户 [当前/默认: ${YELLOW}${OLD_USER}${GREEN} | 输入 ${RED}none${GREEN} 开放免密 | 或自主输入]: ${RESET}")" input_user
    if [ -z "$input_user" ]; then
        if [ "$OLD_USER" = "none" ]; then opt_user=""; opt_pass=""; else opt_user="$OLD_USER"; opt_pass="$OLD_PASS"; fi
    elif [ "$input_user" = "none" ]; then
        opt_user=""; opt_pass=""
    else
        opt_user="$input_user"
        # 如果是新设账户或修改账户，提示输入密码，并提供默认随机/旧密码回车继承
        read -r -p "$(echo -e "${GREEN}请输入连接密码 [当前/默认: ${YELLOW}${OLD_PASS}${GREEN} | 回车不改]: ${RESET}")" input_pass
        opt_pass="${input_pass:-$OLD_PASS}"
    fi

    echo -e "\n${GREEN}==== [选择出站 Profile 路由路径] ====${RESET}"
    echo "1. default (系统默认路由，普通混合网络)"
    echo "2. ipv4    (IPv4-only，强制仅解析A记录/仅走v4)"
    echo "3. ipv6    (IPv6-only，强制仅解析AAAA记录/仅走v6)"
    read -r -p "选择出站路径序号 [1-3, 回车不修改]: " outbound_choice
    local opt_outbound="$OLD_OUTBOUND"
    if [ "$outbound_choice" = "1" ]; then opt_outbound="default"; elif [ "$outbound_choice" = "2" ]; then opt_outbound="ipv4"; elif [ "$outbound_choice" = "3" ]; then opt_outbound="ipv6"; fi

    if [ ! -f "$BIN_PATH" ]; then
        download_bin
        install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH"
        rm -rf "$(dirname "$TARGET_BIN_PATH")"
    fi

    write_config "$CURRENT_INSTANCE" "$opt_proto" "$opt_ip" "$opt_port" "$opt_user" "$opt_pass" "$opt_outbound"
    write_openrc_service

    if [ ! -L "/etc/init.d/micaproxy.${CURRENT_INSTANCE}" ]; then
        ln -sf /etc/init.d/micaproxy "/etc/init.d/micaproxy.${CURRENT_INSTANCE}"
    fi

    info "正在通过 OpenRC 拉起并解锁内核限制实例: ${CURRENT_INSTANCE} ..."
    rc-update add "micaproxy.${CURRENT_INSTANCE}" default >/dev/null 2>&1
    rc-service "micaproxy.${CURRENT_INSTANCE}" restart
    
    sleep 1.2
    ok "MicaProxy OpenRC 实例 [ ${CURRENT_INSTANCE} ] 部署成功！"
    print_node_summary "$CURRENT_INSTANCE"
}

menu_uninstall() {
    warn "该操作将彻底销毁当前选定的 OpenRC 实例。"
    read -r -p "$(echo -e "${RED}确认抹除实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" res
    case "$res" in [Yy]*) ;; *) return ;; esac

    rc-service "micaproxy.${CURRENT_INSTANCE}" stop >/dev/null 2>&1
    rc-update del "micaproxy.${CURRENT_INSTANCE}" >/dev/null 2>&1
    rm -f "/etc/init.d/micaproxy.${CURRENT_INSTANCE}"
    rm -f "${INSTANCE_DIR}/${CURRENT_INSTANCE}.toml"
    ok "实例 [ ${CURRENT_INSTANCE} ] 已干净销毁。"
}

rand_seed=17

while true; do
    get_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈ MicaProxy SOCKS5/HTTP 多实例管理面板 ◈  ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} 1. 安装 当前控制实例${RESET}"
    echo -e "${GREEN} 2. 更新 当前控制实例${RESET}"
    echo -e "${GREEN} 3. 卸载 当前控制实例${RESET}"
    echo -e "${GREEN} 4. 修改 当前控制实例${RESET}"
    echo -e "${GREEN} 5. 启动 当前控制实例${RESET}"
    echo -e "${GREEN} 6. 停止 当前控制实例${RESET}"
    echo -e "${GREEN} 7. 重启 当前控制实例${RESET}"
    echo -e "${GREEN} 8. 查看当前实例日志${RESET}"
    echo -e "${GREEN} 9. 查看当前实例配置${RESET}"
    echo -e "${YELLOW}10.切换实例名字/多开新建不限数量的代理✨${RESET}"
    echo -e "${GREEN} 0. 退出控制面板${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice
    case "$choice" in
        1) menu_install "new" ;;
        2) download_bin && install -m 0755 -o root -g root "$TARGET_BIN_PATH" "$BIN_PATH" && rm -rf "$(dirname "$TARGET_BIN_PATH")" && ok "核心覆盖成功" ;;
        3) menu_uninstall ;;
        4) menu_install "edit" ;;
        5) rc-service "micaproxy.${CURRENT_INSTANCE}" start && ok "拉起成功" ;;
        6) rc-service "micaproxy.${CURRENT_INSTANCE}" stop && ok "挂起成功" ;;
        7) rc-service "micaproxy.${CURRENT_INSTANCE}" restart && ok "重启完毕" ;;
        8) if [ -f "/opt/MicaProxy/log/${CURRENT_INSTANCE}.log" ]; then tail -n 50 -f "/opt/MicaProxy/log/${CURRENT_INSTANCE}.log"; else warn "暂无运行日志生成"; fi ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_instance ;;
        0) exit 0 ;;
        *) warn "无效输入！"; sleep 1 ;;
    esac
    read -r -p "$(echo -e "${GREEN}按任意键重新返回控制台面...${RESET}")" dummy
done
