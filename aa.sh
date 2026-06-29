#!/bin/sh

# =============================================================================
#  Xray VLESS-Encryption  多实例管理面板 (Alpine Linux OpenRC 专属版)
# =============================================================================

set -Eu

# ── 核心路径与环境变量 ────────────────────────────────────────────────────────
export TEMPLATE_NAME="vlessenc"
export BIN_PATH="/usr/local/bin/${TEMPLATE_NAME}"
export CONFIG_DIR="/usr/local/etc/${TEMPLATE_NAME}"
export LOG_DIR="/var/log/${TEMPLATE_NAME}"
export LINK_DIR="/root/proxynode/encryption"

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
    "https://v6.gh-proxy.org/"
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://proxy.vvvv.ee/"
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

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR]请使用 root 权限运行此脚本！${RESET}" >&2
    exit 1
fi

# ── 底层依赖检测与补全 ─────────────────────────────
REQUIRED_CMDS="curl sed grep awk openssl wget netstat unzip jq uuidgen gcompat libc6-compat"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo -e "${YELLOW}[INFO]检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${YELLOW}，正在自动安装...${RESET}"
    apk update -q && apk add -q jq curl wget openssl unzip gcompat libc6-compat >/dev/null 2>&1
    echo -e "${GREEN}[OK]基础依赖补全成功！${RESET}"
fi

# ── 安全验证组件 ─────────────────────────────────────
check_port() {
    local port="$1"
    if netstat -tuln 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then return 1; fi
    return 0
}
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; sleep 0.01; }
is_valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
is_valid_alias() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }

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
    echo "127.0.0.1" && return 0
}

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) 
            echo -e "${RED}[ERROR]暂不支持的系统架构: $(uname -m)${RESET}" >&2
            exit 1 
            ;;
    esac
}

# ── 注册表核心引擎 ───────────────────────────────────────────────────
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

sync_registry() {
    mkdir -p "$CONFIG_DIR"
    touch "$REGISTRY_FILE"
    local temp_reg="${TMP_DIR}/sync.env"
    touch "$temp_reg"
    
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
    echo -e "${YELLOW}[INFO]正在轮询获取 Xray-core 最新 Release 版本号...${RESET}"
    VERSION=""
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local api_url="${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        local resp
        resp=$(wget -qO- --timeout=5 --tries=1 --no-check-certificate "$api_url" 2>/dev/null) || continue
        local tmp_ver
        tmp_ver=$(echo "$resp" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -n "$tmp_ver" && "$tmp_ver" != "null" ]]; then
            VERSION="${tmp_ver#v}"
            echo -e "${GREEN}[OK]成功获取到最新版本: ${VERSION}${RESET}"
            break
        fi
    done
    if [ -z "$VERSION" ]; then
        VERSION="$BACKUP_VERSION"
        echo -e "${YELLOW}[WARN]降级采用稳定默认版本: ${VERSION}${RESET}"
    fi
}

download_bin() {
    local arch
    arch=$(get_arch)
    fetch_latest_version
    local download_success=false
    
    for proxy in "${GITHUB_PROXIES[@]}"; do
        local url_bin="${proxy}https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-linux-${arch}.zip"
        echo -e "${YELLOW}[INFO]正在尝试通过镜像源 [ ${CYAN}${proxy:-官方直连}${YELLOW} ] 下载资产包...${RESET}"
        if curl -fsSL --connect-timeout 8 --max-time 60 -o "$TMP_DIR/xray.zip" "$url_bin"; then
            if [ -s "$TMP_DIR/xray.zip" ]; then
                download_success=true
                unzip -qo "$TMP_DIR/xray.zip" -d "$TMP_DIR/extracted"
                echo -e "${GREEN}[OK]核心包同步下载与解压完成！${RESET}"
                break
            fi
        fi
        echo -e "${YELLOW}[WARN]当前源下载失败或连接超时，正在为您自动切换下一个备用源...${RESET}"
    done

    if [ "$download_success" = "false" ]; then
        echo -e "${RED}[ERROR]所有 GitHub 镜像代理源及官方通道均尝试失败，请检查 network 后重试！${RESET}" >&2
        exit 1
    fi
}

# 写入 OpenRC 服务模板脚本
write_template_service() {
    local instance="$1"
    local init_file="/etc/init.d/${TEMPLATE_NAME}-${instance}"
    local log_file="${LOG_DIR}/${instance}.log"
    touch "$log_file"

    cat > "$init_file" <<EOF
#!/sbin/openrc-run
description="Xray Vless Encryption Service (Instance: ${instance})"
command="${BIN_PATH}"
command_args="run -config ${CONFIG_DIR}/config_${instance}.json"
command_background="yes"
pidfile="/run/${TEMPLATE_NAME}-${instance}.pid"
output_log="${log_file}"
error_log="${log_file}"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$init_file"
}

init_environment() {
    install -m 0755 -d "$(dirname "$BIN_PATH")"
    install -m 0755 -d "$CONFIG_DIR"
    install -m 0755 -d "$LOG_DIR"
    install -m 0755 -d "$LINK_DIR"
}

# ── VLESS Encryption 专用加解密提取对提取引擎 ─────────────────────────
generate_vless_encryption_pair() {
    local vlessenc_output
    vlessenc_output=$($BIN_PATH vlessenc 2>/dev/null || true)
    if [ -z "$vlessenc_output" ]; then return 1; fi

    local decryption_config=""
    local encryption_config=""
    local in_mlkem_section=false

    while IFS= read -r line; do
        if [[ "$line" == *"Authentication: ML-KEM-768, Post-Quantum"* ]]; then
            in_mlkem_section=true
            continue
        fi
        if [ "$in_mlkem_section" = true ]; then
            if [[ "$line" == *'"decryption":'* ]]; then
                decryption_config=$(echo "$line" | sed 's/.*"decryption": "\([^"]*\)".*/\1/')
            elif [[ "$line" == *'"encryption":'* ]]; then
                if echo "$line" | grep -q '.*"encryption": "[^"]*"'; then
                    encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\)..*/\1/')
                else
                    encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\).*/\1/')
                    read -r next_line
                    encryption_config="${encryption_config}${next_line}"
                    encryption_config=$(echo "$encryption_config" | tr -d '"' | tr -d '[:space:]')
                fi
                break
            fi
        fi
    done <<< "$vlessenc_output"

    if [ -z "$decryption_config" ] || [ -z "$encryption_config" ]; then return 1; fi
    echo "${decryption_config}|${encryption_config}"
}

write_config() {
    local instance="$1" port="$2" uuid="$3" decryption="$4" encryption="$5" remark="$6"
    local conf_file="${CONFIG_DIR}/config_${instance}.json"
    
    jq -n \
        --arg port_str "${port}" \
        --arg uuid "${uuid}" \
        --arg decryption "${decryption}" \
        --arg flow "xtls-rprx-vision" \
        --arg instance "${instance}" \
        --arg encryption "${encryption}" \
        --arg remark "${remark}" \
    '{
      "log": { "loglevel": "warning" },
      "inbounds": [{
        "listen": "::",
        "port": ($port_str | tonumber),
        "protocol": "vless",
        "settings": {
          "clients": [{ "id": $uuid, "flow": $flow }],
          "decryption": $decryption
        }
      }],
      "outbounds": [{ "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4v6" } }],
      "_meta": { "alias": $instance, "encryption": $encryption, "remark": $remark }
    }' > "$conf_file"

    chmod 0644 "$conf_file"
    register_instance "$instance"
}

generate_link() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    [[ ! -f "$file" ]] && return 1
    
    local ip uuid port encryption remark display_ip encoded_remark
    ip=$(get_public_ip)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null || echo "")
    port=$(jq -r '.inbounds[0].port' "$file" 2>/dev/null || echo "")
    encryption=$(jq -r '._meta.encryption // empty' "$file" 2>/dev/null || echo "")
    remark=$(jq -r '._meta.remark // empty' "$file" 2>/dev/null || echo "VLESS-Enc")
    
    display_ip="$ip"; [[ "$ip" =~ ":" ]] && display_ip="[$ip]"
    encoded_remark=$(jq -rn --arg x "$remark" '$x|@uri')
    
    cat > "${LINK_DIR}/xray_${instance}.txt" <<EOF
vless://${uuid}@${display_ip}:${port}?encryption=${encryption}&flow=xtls-rprx-vision&type=tcp&security=none#${encoded_remark}
EOF
}

print_node_summary() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    if [ ! -f "$file" ]; then return; fi

    generate_link "$instance"

    echo -e "\n${GREEN}== Xray 实例${RESET}${YELLOW} [ ${instance} ]${RESET} ${GREEN}配置详情 ==${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}VLESS-Encryption (ML-KEM-768)${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} $(get_public_ip)"
    echo -e "${GREEN}监听端口     :${RESET} $(jq -r '.inbounds[0].port' "$file" 2>/dev/null)"
    echo -e "${GREEN}用户凭证UUID :${RESET} $(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null)"
    echo -e "${GREEN}自定义备注   :${RESET} $(jq -r '._meta.remark // empty' "$file" 2>/dev/null)"
    echo -e "${GREEN}配置文件路径 :${RESET} ${file}"
    echo -e "${GREEN}--------------------------------------------${RESET}"
    if [[ -f "${LINK_DIR}/xray_${instance}.txt" ]]; then
        echo -e "${GREEN}👉 标准通用分享链接:${RESET}"
        echo -e "${YELLOW}$(cat "${LINK_DIR}/xray_${instance}.txt")${RESET}"
    fi
    echo ""
}

get_status_info() {
    if rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        panel_status="${GREEN}● 运行中${RESET}"
    else
        panel_status="${RED}● 未运行${RESET}"
    fi

    if [ -f "$BIN_PATH" ]; then
        local real_ver
        real_ver=$($BIN_PATH version 2>/dev/null | grep -i "Xray" | head -n 1 | awk '{print $2}')
        panel_version="${real_ver:-v1.x}"
    else
        panel_version="${RED}未下载核心${RESET}"
    fi

    local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [ -f "$conf_file" ]; then
        local p_num
        p_num=$(jq -r '.inbounds[0].port // empty' "$conf_file" 2>/dev/null)
        panel_port="${p_num} (Encryption)"
        
        local out_proto
        out_proto=$(jq -r '.outbounds[0].protocol // "freedom"' "$conf_file" 2>/dev/null)
        if [[ "$out_proto" == "socks" ]]; then
            panel_outbound="${YELLOW}Socks5出口${RESET}"
        else
            panel_outbound="${YELLOW}直连出口${RESET}"
        fi
    else
        panel_port="未创建配置"
        panel_outbound="${RED}未创建配置${RESET}"
    fi
}

parse_existing_config() {
    local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [ ! -f "$conf_file" ]; then return 1; fi

    OLD_PORT=$(jq -r '.inbounds[0].port' "$conf_file" 2>/dev/null)
    OLD_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$conf_file" 2>/dev/null)
    OLD_DECRYPTION=$(jq -r '.inbounds[0].settings.decryption' "$conf_file" 2>/dev/null)
    OLD_ENCRYPTION=$(jq -r '._meta.encryption' "$conf_file" 2>/dev/null)
    OLD_REMARK=$(jq -r '._meta.remark // empty' "$conf_file" 2>/dev/null)
    return 0
}

menu_switch_instance() {
    echo -e "\n${GREEN}======== [多开实例矩阵管理中心] ========${RESET}"
    echo -e "${GREEN}当前操作目标:${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目前独立实例列表:${RESET}"

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
            local status_str="${RED}已停止${RESET}"
            rc-service "${TEMPLATE_NAME}-${name}" status 2>/dev/null | grep -q "started" && status_str="${GREEN}运行中${RESET}"
            
            echo -e " ${CYAN}[ ${count} ] ->${RESET} ${YELLOW}${name}${RESET} ${GREEN}[端口: ${port_num} | 状态: ${status_str}${GREEN}]${RESET}"
        done < "$REGISTRY_FILE"
    fi

    if [ "$count" -eq 0 ]; then
        echo -e " ${YELLOW}(暂无任何多开实例，请直接输入新名称创建)${RESET}"
    fi
    
    echo ""
    echo -e "${GREEN}👉 输入现有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文名字】来新建多开实例${RESET}"
    local input_val=""
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true

    if [ -z "$input_val" ]; then return; fi

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            local index=$((input_val - 1))
            CURRENT_INSTANCE="${instance_list[$index]}"
            echo -e "${GREEN}[OK]操作焦点已成功切为编号 [ ${input_val} ] 的实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else
            echo -e "${YELLOW}[WARN]编号输入超出范围！未做任何变更。${RESET}"
        fi
    else
        if is_valid_alias "$input_val"; then
            CURRENT_INSTANCE="$input_val"
            echo -e "${GREEN}[OK]检测到全新实例名称，已将焦点锁定在:${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET} ${GREEN}(请去主菜单按 1 创建它)${RESET}"
        else
            echo -e "${RED}[ERROR]名字仅限英文字母/数字/下划线！${RESET}" >&2
        fi
    fi
}

menu_install() {
    init_environment
    local is_edit=false
    if [ "$1" = "edit" ]; then is_edit=true; fi

    if [ "$is_edit" = "true" ]; then
        if ! parse_existing_config; then
            echo -e "${RED}[ERROR]未检测到实例 [ ${CURRENT_INSTANCE} ] 的旧配置，无法执行修改，请先按 1 进行全新部署！${RESET}" >&2
            exit 1
        fi
        echo -e "\n${GREEN}==== [💡 正在修改实例: ${CURRENT_INSTANCE} (直接回车保持原样)] ====${RESET}"
    else
        local conf_file="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
        if [ -f "$conf_file" ]; then
            echo -e "${YELLOW}[WARN]实例 [ ${CURRENT_INSTANCE} ] 已经存在对应配置文件。${RESET}"
            local res=""
            read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重写该实例？[y/N]: ${RESET}")" res || true
            [[ "$res" =~ ^[Yy]$ ]] || return
        fi
        echo -e "\n${GREEN}==== [配置新实例 ${CURRENT_INSTANCE} 参数] ====${RESET}"
        OLD_PORT=$((RANDOM % 50001 + 10000))
        while ! check_port "$OLD_PORT"; do OLD_PORT=$((RANDOM % 50001 + 10000)); done
        if [ -f "$BIN_PATH" ]; then
            OLD_UUID=$("$BIN_PATH" uuid 2>/dev/null || uuidgen)
        else
            OLD_UUID=$(uuidgen 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")
        fi
        OLD_REMARK="VLESS-Enc-${CURRENT_INSTANCE}"
        OLD_DECRYPTION="" OLD_ENCRYPTION=""
    fi

    # 1. 端口绑定
    local input_port="" opt_port=""
    read -r -p "$(echo -e "${GREEN}请输入服务入站端口 [当前: ${YELLOW}${OLD_PORT}${GREEN} | 回车不改]: ${RESET}")" input_port || true
    opt_port="${input_port:-$OLD_PORT}"
    if [ "$opt_port" != "$OLD_PORT" ] || [ "$is_edit" = "false" ]; then
        if ! is_valid_port "$opt_port"; then 
            echo -e "${RED}[ERROR]无效端口，强制应用默认随机端口。${RESET}" >&2
            opt_port="$OLD_PORT"
        fi
        if ! check_port "$opt_port"; then 
            echo -e "${YELLOW}[WARN]警告：检测到端口 ${opt_port} 可能被占用！${RESET}"
        fi
    fi

    # 2. 用户 UUID
    local input_uuid="" opt_uuid=""
    read -r -p "$(echo -e "${GREEN}请输入用户凭证 UUID [当前: ${YELLOW}${OLD_UUID}${GREEN} | 回车不改]: ${RESET}")" input_uuid || true
    opt_uuid="${input_uuid:-$OLD_UUID}"

    # 3. 自定义备注
    local input_remark="" opt_remark=""
    read -r -p "$(echo -e "${GREEN}请输入节点自定义备注 [当前: ${YELLOW}${OLD_REMARK}${GREEN} | 回车不改]: ${RESET}")" input_remark || true
    opt_remark="${input_remark:-$OLD_REMARK}"

    if [ ! -f "$BIN_PATH" ]; then
        download_bin
        install -m 0755 -o root -g root "$TMP_DIR/extracted/xray" "$BIN_PATH"
        cp -f "$TMP_DIR/extracted/geoip.dat" "$TMP_DIR/extracted/geosite.dat" "${CONFIG_DIR}/" 2>/dev/null || true
    fi

    # 4. 处理底层加解密对生成 (编辑模式下原地继承，防掉线)
    local opt_decryption="$OLD_DECRYPTION" local opt_encryption="$OLD_ENCRYPTION"
    if [ -z "$opt_decryption" ] || [ "$is_edit" = "false" ]; then
        echo -e "${YELLOW}[INFO]正在为您动态生成 ML-KEM 抗量子加解密对基础底座...${RESET}"
        local enc_pair
        enc_pair=$(generate_vless_encryption_pair) || { echo -e "${RED}[ERROR]获取内核加解密底座对失败，请检查核心兼容性。${RESET}" >&2; return 1; }
        opt_decryption=$(echo "$enc_pair" | cut -d'|' -f1)
        opt_encryption=$(echo "$enc_pair" | cut -d'|' -f2)
    fi

    write_config "$CURRENT_INSTANCE" "$opt_port" "$opt_uuid" "$opt_decryption" "$opt_encryption" "$opt_remark"
    write_template_service "$CURRENT_INSTANCE"

    echo -e "${YELLOW}[INFO]正在安全重载实例配置项并拉起: ${CURRENT_INSTANCE} ...${RESET}"
    rc-update add "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" restart
    
    sleep 1.5
    if rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}[OK]Xray Encryption 实例 [ ${CURRENT_INSTANCE} ] 部署/修改成功！${RESET}"
        print_node_summary "$CURRENT_INSTANCE"
    else
        echo -e "${YELLOW}[WARN]实例重启成功，但检测到异常挂起，请按 [8] 抓取内核滚动日志排查。${RESET}"
    fi
}

menu_uninstall() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁当前聚焦选择的 Encryption 实例及其占用的端口通道。${RESET}"
    local res=""
    read -r -p "$(echo -e "${RED}确认抹除清理实例 [ ${CURRENT_INSTANCE} ] 吗？[y/N]: ${RESET}")" res || true
    [[ "$res" =~ ^[Yy]$ ]] || return

    rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" stop >/dev/null 2>&1 || true
    rc-update del "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${TEMPLATE_NAME}-${CURRENT_INSTANCE}"
    rm -f "${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    rm -f "${LINK_DIR}/xray_${CURRENT_INSTANCE}.txt"
    rm -f "${LOG_DIR}/${CURRENT_INSTANCE}.log"
    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}[OK]实例 [ ${CURRENT_INSTANCE} ] 已被纯净抹除。${RESET}"

    if [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" | grep 'config_')" ]; then
        echo -e "${YELLOW}[INFO]检测到所有 Encryption 节点已排空，执行全局核心组件垃圾回收机制...${RESET}"
        for init_script in /etc/init.d/${TEMPLATE_NAME}-*; do
            [ -e "$init_script" ] || continue
            local inst_name=$(basename "$init_script" | sed "s/^${TEMPLATE_NAME}-//")
            rc-service "${TEMPLATE_NAME}-${inst_name}" stop >/dev/null 2>&1 || true
            rc-update del "${TEMPLATE_NAME}-${inst_name}" default >/dev/null 2>&1 || true
            rm -f "$init_script"
        done
        rm -f "$BIN_PATH" "$REGISTRY_FILE"
        rm -rf "$CONFIG_DIR" "$LOG_DIR"
        rm -f "${LINK_DIR}"/xray_*.txt 2>/dev/null || true
        echo -e "${GREEN}[OK]全系统已无常驻残留，基础依赖与内核解绑卸载完成！${RESET}"
        CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "Xray")"
    fi
}

configure_custom_socks5_outbound() {
    local instance_config="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [[ ! -f "$instance_config" ]]; then 
        echo -e "${RED}[ERROR]未安装，无法配置出口模式。${RESET}" >&2
        return
    fi

    local mode current_protocol tmp_file
    current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$instance_config" 2>/dev/null || echo "freedom")

    echo -e "${GREEN}-------------------------------------------${RESET}"
    echo -e "${YELLOW}请选择出口模式：${RESET}"
    if [[ "$current_protocol" == "socks" ]]; then
        echo -e "${GREEN}当前模式:${RESET} ${YELLOW}Socks5${RESET}"
    else
        echo -e "${GREEN}当前模式:${RESET} ${YELLOW}直连${RESET}"
    fi
    echo -e "${GREEN}1) 直连出口${RESET}"
    echo -e "${GREEN}2) Socks5出口${RESET}"
    echo -e "${GREEN}0) 取消${RESET}"
    echo -e "${GREEN}-------------------------------------------${RESET}"

    echo -ne "${YELLOW}请输入选项: ${RESET}"
    read -r mode || true
    case "$mode" in
        1)
            tmp_file=$(mktemp)
            jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$instance_config" > "$tmp_file"
            if ! jq empty "$tmp_file" >/dev/null 2>&1; then
                rm -f "$tmp_file"
                echo -e "${RED}[ERROR]生成的直连配置无效。${RESET}" >&2
                return 1
            fi
            cp "$instance_config" "${instance_config}.bak.$(date +%s)"
            mv "$tmp_file" "$instance_config"
            chmod 644 "$instance_config" 2>/dev/null || true
            
            rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" restart
            sleep 0.5
            if rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
                echo -e "${GREEN}[OK]已成功切换为直连出口！${RESET}"
            else
                echo -e "${RED}[ERROR]切换到直连失败。${RESET}" >&2
                return 1
            fi
            return
            ;;
        2)
            ;;
        0|"")
            echo -e "${YELLOW}[INFO]已取消配置。${RESET}"
            return
            ;;
        *)
            echo -e "${RED}[ERROR]无效选项，请输入 0-2 之间的数字。${RESET}" >&2
            return 1
            ;;
    esac

    echo -e "${YELLOW}[INFO]配置自定义 Socks5 出口代理...${RESET}"

    local socks_host socks_port socks_user socks_pass

    read -rp "请输入 Socks5 服务器地址/IP: " socks_host || true
    [[ -z "$socks_host" ]] && echo -e "${YELLOW}[INFO]已取消配置。${RESET}" && return

    while true; do
        read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port || true
        [[ -z "$socks_port" ]] && socks_port=1080
        if is_valid_port "$socks_port"; then
            break
        else
            echo -e "${RED}[ERROR]端口无效，请输入一个1-65535之间的数字。${RESET}" >&2
        fi
    done

    read -rp "请输入 Socks5 用户名 (若无密码认证请直接留空回车): " socks_user || true
    if [[ -n "$socks_user" ]]; then
        read -rs -p "请输入 Socks5 密码: " socks_pass || true
        echo
    else
        socks_pass=""
    fi

    tmp_file=$(mktemp)

    if [[ -n "$socks_user" ]]; then
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            --arg user "$socks_user" \
            --arg pass "$socks_pass" \
            '
            .outbounds = [
              {
                "protocol": "socks",
                "tag": "custom-socks5-out",
                "settings": {
                  "servers": [
                    {
                      "address": $host,
                      "port": $port,
                      "users": [
                        {
                          "user": $user,
                          "pass": $pass
                        }
                      ]
                    }
                  ]
                }
              }
            ]
            ' "$instance_config" > "$tmp_file"
    else
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            '
            .outbounds = [
              {
                "protocol": "socks",
                "tag": "custom-socks5-out",
                "settings": {
                  "servers": [
                    {
                      "address": $host,
                      "port": $port
                    }
                  ]
                }
              }
            ]
            ' "$instance_config" > "$tmp_file"
    fi

    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        echo -e "${RED}[ERROR]生成的 Socks5 配置无效，请检查输入后重试。${RESET}" >&2
        return 1
    fi

    cp "$instance_config" "${instance_config}.bak.$(date +%s)"
    mv "$tmp_file" "$instance_config"
    chmod 644 "$instance_config" 2>/dev/null || true

    rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" restart
    sleep 0.5
    if rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}[OK]已成功切换为 Socks5 出口！${RESET}"
    else
        echo -e "${RED}[ERROR]重启服务失败，当前配置可能与环境不兼容。${RESET}" >&2
        return 1
    fi
}

# ── 循环路由守护 ────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN} ◈ Xray VLESS-Encryption  多实例管理面板 ◈ ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}目标实例绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}服务活跃状态 :${RESET} $panel_status"
    echo -e "${GREEN}核心沙箱引擎 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}链式分流代理 :${RESET} $panel_outbound"
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
    echo -e "${GREEN}10. Socks5出口${RESET}     ${YELLOW}← 链式分流代理${RESET}"
    echo -e "${GREEN}11. 管理实例${RESET}       ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    
    choice=""
    read -r -p "$(echo -e "${GREEN}选择操作序号: ${RESET}")" choice || true
    case "$choice" in
        1) menu_install "new" ;;
        2) download_bin && install -m 0755 -o root -g root "$TMP_DIR/extracted/xray" "$BIN_PATH" && echo -e "${GREEN}[OK]Xray 核心更新成功${RESET}" ;;
        3) menu_uninstall ;;
        4) menu_install "edit" ;;
        5) rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" start && echo -e "${GREEN}[OK]启动成功${RESET}" ;;
        6) rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" stop && echo -e "${GREEN}[OK]停止成功${RESET}" ;;
        7) rc-service "${TEMPLATE_NAME}-${CURRENT_INSTANCE}" restart && echo -e "${GREEN}[OK]重启完毕${RESET}" ;;
        8) 
            if [ -f "${LOG_DIR}/${CURRENT_INSTANCE}.log" ]; then
                (trap 'echo -e "\n"' INT; tail -n 50 -f "${LOG_DIR}/${CURRENT_INSTANCE}.log")
            else
                echo -e "${RED}[ERROR]暂无日志文件生成。${RESET}"
            fi
            ;;
        9) print_node_summary "$CURRENT_INSTANCE" ;;
        10) configure_custom_socks5_outbound ;;
        11) menu_switch_instance ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[WARN]无效输入！${RESET}"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制台面...${RESET}")" || true
done
