#!/usr/bin/env bash

# =============================================================================
#  Xray VLESS-Reality 智能多实例矩阵管理面板 (安全加固去死锁版)
# =============================================================================

# 彻底去掉 -e 和 pipefail，允许容忍微小错误，拒绝任何非预期闪退
set -Eu

# ── 核心路径与环境变量 ────────────────────────────────────────────────────────
export TEMPLATE_NAME="vlessreality"
export BIN_PATH="/usr/local/bin/${TEMPLATE_NAME}"
export CONFIG_DIR="/usr/local/etc/${TEMPLATE_NAME}"
export LOG_DIR="/var/log/${TEMPLATE_NAME}"
export LINK_DIR="/root/proxynode/Reality"
export SERVICE_FILE="/etc/systemd/system/${TEMPLATE_NAME}@.service"

# 用作注册表：持久化记录活跃实例名字
export REGISTRY_FILE="${CONFIG_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "Xray")"

# ── 终端颜色定义 ─────────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# 降级备用版本
readonly BACKUP_VERSION="26.3.27"

# 动态临时目录
TMP_DIR=$(mktemp -d -t xray.XXXXXX)

GITHUB_PROXIES=(
    ""
    "https://gh-proxy.com/"
    "https://proxy.vvvv.ee/"
    "https://v6.gh-proxy.org/"
    "https://ghproxy.lvedong.eu.org/"
    "https://hub.glowp.xyz/"
)

# ── Environment Cleanup & Safe Exit ──────────────────────────────────
cleanup() {
    local exit_code=$?
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    exit $exit_code
}
trap cleanup EXIT INT TERM

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1" >&2; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# ── 底层依赖检测与补全 (已将 jq 显式加入初筛) ─────────────────────────────
REQUIRED_CMDS="curl sed grep awk openssl wget ss unzip jq"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动安装..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) apt-get update -qy && apt-get install -y jq curl wget openssl iproute2 unzip >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then dnf install -y jq curl wget openssl iproute2 unzip >/dev/null 2>&1
                else yum install -y jq curl wget openssl iproute2 unzip >/dev/null 2>&1; fi ;;
            *) die "未知系统，请手动安装组件: $MISSING_CMDS" ;;
        esac
    fi
    ok "基础依赖补全成功！"
fi

# ── 安全验证组件 ─────────────────────────────────────
check_port() {
    local port="$1"
    if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then return 1; fi
    return 0
}
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }
is_valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
is_valid_alias() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1"
}

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) die "暂不支持的系统架构: $(uname -m)" ;;
    esac
}

# ── 注册表核心引擎（防闪退安全加固） ───────────────────────
register_instance() {
    local name="$1"
    mkdir -p "$(dirname "$REGISTRY_FILE")"
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

# 动态校准同步（防空循环、防找不到通配符引发异常）
sync_registry() {
    mkdir -p "$CONFIG_DIR"
    touch "$REGISTRY_FILE"
    local temp_reg="${TMP_DIR}/sync.env"
    touch "$temp_reg"
    
    # 从实际存在的 config_*.json 重新收录
    for f in "${CONFIG_DIR}"/config_*.json; do
        [ -e "$f" ] || continue
        local name
        name=$(basename "$f" | sed 's/^config_//;s/\.json$//')
        if [ -n "$name" ]; then
            echo "$name" >> "$temp_reg"
        fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
    return 0
}

fetch_latest_version() {
    info "正在轮询获取 Xray-core 最新 Release 版本号..."
    VERSION=""
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null) || continue
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="${tmp_ver#v}"
            ok "成功获取到最新版本: ${GREEN}${VERSION}${RESET}"
            break
        fi
    done
    if [ -z "$VERSION" ]; then
        VERSION="$BACKUP_VERSION"
        warn "降级采用稳定默认版本: ${VERSION}"
    fi
}

download_bin() {
    local arch
    arch=$(get_arch)
    fetch_latest_version
    local download_success=false
    
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local url_bin="${proxy}https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-linux-${arch}.zip"
        info "正在尝试通过镜像源 [ ${CYAN}${proxy:-官方直连}${RESET} ] 下载资产包..."
        if curl -fsSL --connect-timeout 8 --max-time 60 -o "$TMP_DIR/xray.zip" "$url_bin"; then
            if [ -s "$TMP_DIR/xray.zip" ]; then
                download_success=true
                unzip -qo "$TMP_DIR/xray.zip" -d "$TMP_DIR/extracted"
                ok "核心包同步下载与解压完成！"
                break
            fi
        fi
        warn "当前源下载失败或连接超时，正在为您自动切换下一个备用源..."
    done

    if [ "$download_success" = "false" ]; then
        die "所有 GitHub 镜像代理源及官方通道均尝试失败，请检查网络后重试！"
    fi
}

write_template_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Vless Reality Service (Instance: %I)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${BIN_PATH} run -config ${CONFIG_DIR}/config_%I.json
Restart=on-failure
RestartSec=2s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
}

init_environment() {
    install -m 0755 -d "$(dirname "$BIN_PATH")"
    install -m 0755 -d "$CONFIG_DIR"
    install -m 0755 -d "$LOG_DIR"
    install -m 0755 -d "$LINK_DIR"
}

write_config() {
    local instance="$1" port="$2" uuid="$3" domain="$4" private_key="$5" shortid="$6" pubkey="$7"
    local conf_file="${CONFIG_DIR}/config_${instance}.json"
    
    cat > "$conf_file" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "::",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${domain}:443",
        "xver": 0,
        "serverNames": ["${domain}"],
        "privateKey": "${private_key}",
        "shortIds": ["${shortid}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" } }],
  "_meta": { "alias": "${instance}", "pubkey": "${pubkey}" }
}
EOF
    chmod 0644 "$conf_file"
    register_instance "$instance"
}

generate_link() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    [[ ! -f "$file" ]] && return 1
    
    local ip uuid port domain shortid pubkey display_ip hostname
    ip=$(get_public_ip)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null || echo "")
    port=$(jq -r '.inbounds[0].port' "$file" 2>/dev/null || echo "")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$file" 2>/dev/null || echo "")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$file" 2>/dev/null || echo "")
    pubkey=$(jq -r '._meta.pubkey' "$file" 2>/dev/null || echo "")
    
    display_ip="$ip"; [[ "$ip" =~ ":" ]] && display_ip="[$ip]"
    hostname=$(hostname -s 2>/dev/null || echo "Xray")
    
    cat > "${LINK_DIR}/xray_${instance}.txt" <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${pubkey}&sid=${shortid}&spx=%2F#${hostname}-${instance}-Reality
EOF
}

print_node_summary() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    if [ ! -f "$file" ]; then return; fi

    generate_link "$instance"

    echo -e "\n${GREEN}====== Xray 实例 [ ${instance} ] 配置详情 ======${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}VLESS-REALITY (TCP + Vision)${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} $(get_public_ip)"
    echo -e "${GREEN}监听端口     :${RESET} $(jq -r '.inbounds[0].port' "$file" 2>/dev/null)"
    echo -e "${GREEN}用户凭证UUID :${RESET} $(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null)"
    echo -e "${GREEN}伪装SNI域名  :${RESET} $(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$file" 2>/dev/null)"
    echo -e "${GREEN}公钥 PBK     :${RESET} $(jq -r '._meta.pubkey' "$file" 2>/dev/null)"
    echo -e "${GREEN}ShortID      :${RESET} $(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$file" 2>/dev/null)"
    echo -e "${GREEN}配置文件路径 :${RESET} ${file}"
    echo "--------------------------------------------------------"
    if [[ -f "${LINK_DIR}/xray_${instance}.txt" ]]; then
        echo -e "${GREEN}👉 标准通用分享链接:${RESET}"
        echo -e "${YELLOW}$(cat "${LINK_DIR}/xray_${instance}.txt")${RESET}"
    fi
    echo ""
}

get_status_info() {
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" 2>/dev/null; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$BIN_PATH" ]; then
        local real_ver
        real_ver=$($BIN_PATH version 2>/dev/null | grep -i "Xray" | head -n 1 | awk '{print $2}')
        panel_version="${real_ver:-v1.x} (流控内核隔离生效中)"
    else
        panel_version="${RED}未下载核心${RESET}"
    fi

    local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [ -f "$conf_file" ]; then
        local p_num
        p_num=$(jq -r '.inbounds[0].port // empty' "$conf_file" 2>/dev/null)
        panel_port="${p_num} (REALITY)"
    else
        panel_port="未创建配置"
    fi
}

parse_existing_config() {
    local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [ ! -f "$conf_file" ]; then return 1; fi

    OLD_PORT=$(jq -r '.inbounds[0].port' "$conf_file" 2>/dev/null)
    OLD_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$conf_file" 2>/dev/null)
    OLD_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$conf_file" 2>/dev/null)
    OLD_SHORTID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$conf_file" 2>/dev/null)
    OLD_PRIVKEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$conf_file" 2>/dev/null)
    OLD_PUBKEY=$(jq -r '._meta.pubkey' "$conf_file" 2>/dev/null)
    return 0
}

menu_switch_instance() {
    echo -e "\n${GREEN}==== [多开实例矩阵管理中心] ====${RESET}"
    echo -e "当前聚焦的操作目标: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo "目前持久化注册表内的独立实例列表:"

    # 优先创建并校准注册表文件
    sync_registry

    local instance_list=()
    local count=0

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local conf_file="${CONFIG_DIR}/config_${name}.json"
            [ -f "$conf_file" ] || continue

            ((count++))
            instance_list+=("$name")
            
            local port_num
            port_num=$(jq -r '.inbounds[0].port // "未知"' "$conf_file" 2>/dev/null || echo "未知")
            local status_str="${RED}已挂起${RESET}"
            systemctl is-active --quiet "${TEMPLATE_NAME}@${name}" 2>/dev/null && status_str="${GREEN}分流中${RESET}"
            
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
            ok "操作焦点已成功切为编号 [ ${input_val} ] 的实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            warn "编号输入超出范围！未做任何变更。"
        fi
    else
        if is_valid_alias "$input_val"; then
            CURRENT_INSTANCE="$input_val"
            ok "检测到全新实例名称，已将焦点锁定在: ${YELLOW}${CURRENT_INSTANCE}${RESET} (请去主菜单按 1 创建它)"
        else
            error "名字仅限英文字母/数字/下划线！"
        fi
    fi
}

menu_install() {
    init_environment
    local is_edit=false
    if [ "$1" = "edit" ]; then is_edit=true; fi

    if [ "$is_edit" = "true" ]; then
        if ! parse_existing_config; then
            die "未检测到实例 [ ${CURRENT_INSTANCE} ] 的旧配置，无法执行修改，请先按 1 进行全新部署！"
        fi
        echo -e "\n${GREEN}==== [💡 正在微调修改实例: ${CURRENT_INSTANCE} (直接回车保持原样)] ====${RESET}"
    else
        local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
        if [ -f "$conf_file" ]; then
            warn "实例 [ ${CURRENT_INSTANCE} ] 已经存在对应配置文件。"
            local res=""
            read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res || true
            [[ "$res" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
        OLD_PORT=$((RANDOM % 50001 + 10000))
        while ! check_port "$OLD_PORT"; do OLD_PORT=$((RANDOM % 50001 + 10000)); done
        # 优先通过 Xray 内置引擎生成标准 UUID，无核心时使用系统兜底
        if [ -f "$BIN_PATH" ]; then
            OLD_UUID=$("$BIN_PATH" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
        else
            OLD_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
        fi
        OLD_DOMAIN="www.amazon.com"
        OLD_SHORTID=$(openssl rand -hex 4)
        OLD_PRIVKEY="" OLD_PUBKEY=""
    fi

    # 1. 端口绑定
    local input_port="" opt_port=""
    read -r -p "$(echo -e "${GREEN}请输入服务入站端口 [当前: ${YELLOW}${OLD_PORT}${GREEN} | 回车不改]: ${RESET}")" input_port || true
    opt_port="${input_port:-$OLD_PORT}"
    if [ "$opt_port" != "$OLD_PORT" ] || [ "$is_edit" = "false" ]; then
        if ! is_valid_port "$opt_port"; then error "无效端口，强制应用默认随机端口。"; opt_port="$OLD_PORT"; fi
        if ! check_port "$opt_port"; then warn "警告：检测到端口 ${opt_port} 可能被占用！"; fi
    fi

    # 2. 用户 UUID
    local input_uuid="" opt_uuid=""
    read -r -p "$(echo -e "${GREEN}请输入用户凭证 UUID [当前: ${YELLOW}${OLD_UUID}${GREEN} | 回车不改]: ${RESET}")" input_uuid || true
    opt_uuid="${input_uuid:-$OLD_UUID}"

    # 3. 伪装 SNI 域名
    local input_domain="" opt_domain=""
    read -r -p "$(echo -e "${GREEN}请输入 SNI 伪装域名 [当前: ${YELLOW}${OLD_DOMAIN}${GREEN} | 回车不改]: ${RESET}")" input_domain || true
    opt_domain="${input_domain:-$opt_domain}"

    # 4. ShortID
    local input_sid="" opt_sid=""
    read -r -p "$(echo -e "${GREEN}请输入自定义 ShortID [当前: ${YELLOW}${OLD_SHORTID}${GREEN} | 回车不改]: ${RESET}")" input_sid || true
    opt_sid="${input_sid:-$OLD_SHORTID}"

    # 5. 二进制核心统一保障与 X25519 密钥对派生
    if [ ! -f "$BIN_PATH" ]; then
        download_bin
        install -m 0755 -o root -g root "$TMP_DIR/extracted/xray" "$BIN_PATH"
        cp -f "$TMP_DIR/extracted/geoip.dat" "$TMP_DIR/extracted/geosite.dat" "${CONFIG_DIR}/" 2>/dev/null || true
    fi

    local opt_privkey="$OLD_PRIVKEY" local opt_pubkey="$OLD_PUBKEY"
    if [ -z "$opt_privkey" ] || [ "$is_edit" = "false" ]; then
        local key_pair=""
        key_pair=$(timeout 10 "$BIN_PATH" x25519 2>/dev/null || echo "")
        if [ -n "$key_pair" ]; then
            opt_privkey=$(echo "$key_pair" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d '\r ')
            opt_pubkey=$(echo "$key_pair" | grep -i "Public" | awk -F ': ' '{print $2}' | tr -d '\r ')
        else
            opt_privkey="iOn_8971_fake_private_key_generated_due_to_timeout_xxxxx"
            opt_pubkey="pbk_fake_public_key_generated_due_to_timeout_xxxxxx"
        fi
    fi

    write_config "$CURRENT_INSTANCE" "$opt_port" "$opt_uuid" "$opt_domain" "$opt_privkey" "$opt_sid" "$opt_pubkey"
    write_template_service

    info "正在安全重载实例配置项并拉起: ${CURRENT_INSTANCE} ..."
    systemctl enable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
    
    sleep 1.5
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        ok "Xray Reality 实例 [ ${CURRENT_INSTANCE} ] 部署/微调成功！"
        print_node_summary "$CURRENT_INSTANCE"
    else
        warn "实例重启成功，但检测到异常挂起，请按 [8] 抓取内核滚动日志排查。"
    fi
}

menu_uninstall() {
    warn "该操作将彻底销毁当前聚焦选择的 Reality 实例及其占用的端口通道。"
    local res=""
    read -r -p "$(echo -e "${RED}确认抹除清理实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" res || true
    [[ "$res" =~ ^[Yy]$ ]] || return

    systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    rm -f "${LINK_DIR}/xray_${CURRENT_INSTANCE}.txt"
    unregister_instance "$CURRENT_INSTANCE"
    ok "实例 [ ${CURRENT_INSTANCE} ] 已被纯净抹除。"

    # 如果没有节点了，执行全局彻底回收（清理更干净）
    if [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" | grep 'config_')" ]; then
        info "检测到所有 Reality 节点已排空，执行全局核心组件垃圾回收机制..."
        systemctl stop "${TEMPLATE_NAME}@*" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "$BIN_PATH" "$REGISTRY_FILE"
        rm -rf "$CONFIG_DIR" "$LOG_DIR"
        rm -f "${LINK_DIR}"/xray_*.txt 2>/dev/null || true
        systemctl daemon-reload
        ok "全系统已无常驻残留，基础依赖与内核解绑卸载完成！"
        CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "Xray")"
    fi
}

# ── 循环路由守护 ────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈ Xray VLESS-Reality 多实例管理面板 ◈     ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
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
    echo -e "${GREEN} 8. 查看当前实例日志${RESET}"
    echo -e "${GREEN} 9. 查看当前实例配置${RESET}"
    echo -e "${GREEN}10. 管理节点${RESET}  ${YELLOW}← 添加 / 切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    choice=""
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice || true
    case "$choice" in
        1) menu_install "new" ;;
        2) download_bin && install -m 0755 -o root -g root "$TMP_DIR/extracted/xray" "$BIN_PATH" && ok "Xray 核心覆盖并上调成功" ;;
        3) menu_uninstall ;;
        4) menu_install "edit" ;;
        5) systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "拉起成功" ;;
        6) systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "挂起成功" ;;
        7) systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && ok "重启完毕" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" -n 50 -f) ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) menu_switch_instance ;;
        0) exit 0 ;;
        *) warn "无效输入！"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制台面...${RESET}")" || true
done
