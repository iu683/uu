#!/usr/bin/env bash
#
# Hysteria 2 多实例管理面板
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

export TEMPLATE_NAME="hysteria"
export BASE_DIR="/etc/mo-hy2"
export INSTALL_BIN="/usr/local/bin/hysteria"
export DATA_BASE_DIR="/var/lib/hysteria"
export HY_DIR_BASE="/root/proxynode/hy2"
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "hy2")"

CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"

PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

firstport=""
endport=""

GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

has_command() { type -P "$1" > /dev/null 2>&1; }
curl() { command curl "${CURL_FLAGS[@]}" "$@"; }
mktemp() { command mktemp "$@" "hyservinst.XXXXXXXXXX"; }

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
ok() { echo -e "${GREEN}[成功] $*${RESET}" >&2; }
pause() { echo; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制面板...${RESET}")"; }

generate_random_password() {
    dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

is_user_exists() { id "$1" > /dev/null 2>&1; }

detect_package_manager() {
    [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]] && return 0
    has_command apt && PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install' && return 0
    has_command dnf && PACKAGE_MANAGEMENT_INSTALL='dnf -y install' && return 0
    has_command yum && PACKAGE_MANAGEMENT_INSTALL='yum -y install' && return 0
    has_command apk && PACKAGE_MANAGEMENT_INSTALL='apk add --no-cache' && return 0
    return 1
}

install_software() {
    local _package_name="$1"
    if ! detect_package_manager; then
        echo -e "${YELLOW}[INFO]未检测到支持的包管理器，请手动安装 $_package_name${RESET}"
        exit 65
    fi
    $PACKAGE_MANAGEMENT_INSTALL $_package_name >/dev/null 2>&1 || true
}

check_environment() {
    if [[ "x$(uname)" != "xLinux" ]]; then
        echo -e "${RED}[INFO]本脚本仅支持 Linux 系统。${RESET}"
        exit 95
    fi

    case "$(uname -m)" in
        'i386' | 'i686') ARCHITECTURE='386' ;;
        'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
        'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='arm' ;;
        'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
        's390x') ARCHITECTURE='s390x' ;;
        *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
    esac
    OPERATING_SYSTEM=linux

    has_command curl || install_software curl
    has_command grep || install_software grep
    has_command jq || install_software jq
    has_command openssl || install_software openssl
    has_command socat || install_software socat
    has_command python3 || install_software python3
    has_command iptables || install_software iptables
}

get_installed_version() {
    if [[ -f "$INSTALL_BIN" ]]; then
        local version_out
        version_out=$("$INSTALL_BIN" version 2>/dev/null || "$INSTALL_BIN" -v 2>/dev/null || echo "")
        if [[ -n "$version_out" ]]; then
            echo "$version_out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
        else echo "未知版本"; fi
    else echo "未安装核心"; fi
}

get_latest_version() {
    local _tmpfile=$(mktemp)
    local _success=1
    local _tag_name=""

    for proxy in "${GITHUB_PROXY[@]}"; do
        local _url="${proxy}${API_BASE_URL}/releases/latest"
        if curl -sS -H 'Accept: application/vnd.github.v3+json' "$_url" -o "$_tmpfile"; then
            _tag_name=$(jq -r '.tag_name' "$_tmpfile" 2>/dev/null || echo "")
            if [[ -n "$_tag_name" && "$_tag_name" != "null" ]]; then
                _success=0
                break
            fi
        fi
    done
    rm -f "$_tmpfile"
    if [[ $_success -eq 0 ]]; then echo "${_tag_name##*\/}"; else echo ""; fi
}

download_hysteria() {
    local _version="$1"
    local _destination="$2"
    [[ ! "$_version" =~ "v" ]] && _version="v$_version"

    for proxy in "${GITHUB_PROXY[@]}"; do
        local _download_url="${proxy}${REPO_URL}/releases/download/app/$_version/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
        echo -e "${YELLOW}正在通过代理 [${proxy:-直连}] 下载 Hysteria 核心 (尝试1) ...${RESET}"
        if curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then return 0; fi

        _download_url="${proxy}${REPO_URL}/releases/download/$_version/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
        echo -e "${YELLOW}正在通过代理 [${proxy:-直连}] 下载 Hysteria 核心 (尝试2) ...${RESET}"
        if curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then return 0; fi
    done
    echo -e "${YELLOW}核心下载失败！所有代理及直连均无法访问。${RESET}"
    return 11
}

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
    local temp_reg=$(mktemp)
    for f in "${BASE_DIR}"/config_*.yaml; do
        [ -e "$f" ] || continue
        local name=$(basename "$f" | sed 's/^config_//;s/\.yaml$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

write_systemd_template() {
    local template_file="/etc/systemd/system/hysteria-server@.service"
    cat << EOF > "$template_file"
[Unit]
Description=Hysteria 2 Server Service - Instance: %I
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_BIN server --config ${BASE_DIR}/config_%I.yaml
WorkingDirectory=${DATA_BASE_DIR}/%I
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

fix_external_cert_permission() {
    local cert=$1 key=$2 target_user=${3:-hysteria}
    if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
        echo -e "${RED}拒绝: 检测到您的证书位于 /root/ 目录下！非 root 运行用户无权穿透读取。${RESET}"
        echo -e "${RED}推荐: 请重新导出证书到公共目录（如 /etc/ssl/ ）再试。${RESET}"
        return 1
    fi
    local cert_dir=$(dirname "$cert")
    chmod +x "$cert_dir" 2>/dev/null || true
    chmod 644 "$cert" "$key" 2>/dev/null || true
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:"$target_user":rx "$cert_dir" 2>/dev/null || true
        setfacl -m u:"$target_user":r "$cert" "$key" 2>/dev/null || true
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

check_port() {
    local port="$1"
    if ss -tunlp 2>/dev/null | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
        return 1
    fi
    return 0
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_random_port() {
    local rand_port
    while true; do
        rand_port=$(shuf -i 2000-65535 -n 1)
        check_port "$rand_port" && echo "$rand_port" && return 0
    done
}

get_hy_status() {
    if systemctl is-active --quiet "hysteria-server@${CURRENT_INSTANCE}" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_current_port_display() {
    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.yaml"
    local hy_dir="${HY_DIR_BASE}/${CURRENT_INSTANCE}"
    if [[ -f "$conf_file" ]]; then
        local main_port=$(grep -E '^listen:' "$conf_file" | awk -F ':' '{print $3}' | tr -d ' ')
        if [[ -f "$hy_dir/hy-client.yaml" ]]; then
            local jump_range=$(grep -E '^server:' "$hy_dir/hy-client.yaml" | awk -F ',' '{print $2}' | tr -d ' ')
            [[ -n "$jump_range" ]] && echo "${main_port} [跳跃: ${jump_range}]" && return
        fi
        echo "${main_port:- -}"
    else echo "实例未初始化"; fi
}

inst_cert() {
    local instance="$1"
    local cert_path="${BASE_DIR}/server_${instance}.crt"
    local key_path="${BASE_DIR}/server_${instance}.key"
    local conf_file="${BASE_DIR}/config_${instance}.yaml"

    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        echo "---------------------------------------------"
        echo -e "${YELLOW}[提示] 检测到实例 [ ${instance} ] 已有历史证书文件。${RESET}"
        read -rp "是否要重新更改证书配置？[y/N] (直接回车保持不变): " cert_change_choice
        cert_change_choice=${cert_change_choice:-n}
        if [[ ! "$cert_change_choice" =~ ^[Yy]$ ]]; then
            info "保持原有证书配置不变。"
            local old_sni="www.bing.com"
            [[ -f "${HY_DIR_BASE}/${instance}/hy-client.yaml" ]] && old_sni=$(grep -E '^\s*sni:' "${HY_DIR_BASE}/${instance}/hy-client.yaml" | awk '{print $2}' | tr -d '"'\' || true)
            export EVAL_CERT_PATH="$cert_path"
            export EVAL_KEY_PATH="$key_path"
            export EVAL_DOMAIN="${old_sni:-"www.bing.com"}"
            return 0
        fi
    fi

    echo "---------------------------------------------"
    echo -e "实例 [ ${instance} ] 证书配置选择："
    echo -e " 1) 必应自签证书${YELLOW}（默认）${RESET}"
    echo -e " 2) Acme自动申请 (需临时放行公网 80 端口)"
    echo -e " 3) 自定义外部证书路径"
    echo "---------------------------------------------"
    local certInput
    read -rp "请输入选项 [1-3] (回车默认自签): " certInput
    certInput=${certInput:-1}

    if [[ $certInput == 2 ]]; then
        local vps_ip=$(get_public_ip)
        read -rp "请输入要绑定的域名: " domain
        [[ -z $domain ]] && error "未输入域名，操作取消！" && return 1

        local acme_cmd="/root/.acme.sh/acme.sh"
        if [[ ! -f "$acme_cmd" ]]; then
            curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
        fi
        "$acme_cmd" --set-default-ca --server letsencrypt
        local reload_cmd="systemctl restart hysteria-server@${instance}"
        if [[ "$vps_ip" =~ ":" ]]; then
            "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
        else
            "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
        fi

        if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc --reloadcmd "$reload_cmd"; then
            hy_domain=$domain
            info "Acme 独立实例证书部署成功！"
        else
            error "Acme 申请失败，降级回自签模式。"
            certInput=1
        fi
    elif [[ $certInput == 3 ]]; then
        while true; do
            local user_cert user_key
            read -rp "请输入公钥文件 (fullchain.pem/crt) 绝对路径: " user_cert
            read -rp "请输入密钥文件 (privkey.pem/key) 绝对路径: " user_key
            read -rp "请输入对应域名: " hy_domain
            if [[ -f "$user_cert" && -f "$user_key" ]]; then
                rm -f "$cert_path" "$key_path"
                fix_external_cert_permission "$user_cert" "$user_key" "hysteria" || continue
                ln -sf "$user_cert" "$cert_path"
                ln -sf "$user_key" "$key_path"
                break
            else
                error "路径未找到，请重新输入！"
            fi
        done
    fi

    if [[ $certInput == 1 ]]; then
        rm -f "$cert_path" "$key_path"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        hy_domain="www.bing.com"
    fi

    chown -h hysteria:hysteria "$cert_path" "$key_path" 2>/dev/null || true
    export EVAL_CERT_PATH="$cert_path"
    export EVAL_KEY_PATH="$key_path"
    export EVAL_DOMAIN="$hy_domain"
}

inst_port() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.yaml"
    local hy_dir="${HY_DIR_BASE}/${instance}"
    local default_port=""
    local old_first="" old_end=""

    [[ -f "$conf_file" ]] && default_port=$(grep -E '^listen:' "$conf_file" | awk -F ':' '{print $3}' | tr -d ' ')
    
    if [[ -f "$hy_dir/hy-client.yaml" ]]; then
        local old_range=$(grep -E '^server:' "$hy_dir/hy-client.yaml" | awk -F ',' '{print $2}' | tr -d ' ')
        if [[ -n "$old_range" && "$old_range" == *"-"* ]]; then
            old_first=$(echo "$old_range" | cut -d'-' -f1)
            old_end=$(echo "$old_range" | cut -d'-' -f2)
        fi
    fi

    local prompt_msg="设置该实例监听主端口 (回车随机分配): "
    [[ -n "$default_port" ]] && prompt_msg="设置该实例监听主端口 [当前: ${default_port}, 回车不修改]: "

    while true; do
        read -rp "$prompt_msg" port
        port=${port:-$default_port}
        [[ -z "$port" ]] && port=$(get_random_port) && info "为您分发未占用端口: $port" && break
        if is_valid_port "$port"; then
            if [[ "$port" != "$default_port" ]] && ! check_port "$port"; then
                error "端口 ${port} 已被占用，请更换。" && continue
            fi
            break
        else error "请输入合法端口数字！"; fi
    done

    iptables -t nat -F "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
    iptables -t nat -D PREROUTING -j "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
    iptables -t nat -X "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -F "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -D PREROUTING -j "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -X "HY2_JUMP_${instance}" >/dev/null 2>&1 || true

    echo "---------------------------------------------"
    echo -e "实例端口流控模式选择："
    echo -e " 1) 单端口独立模式"
    echo -e " 2) 端口跳跃分流模式${YELLOW}（默认）${RESET}"
    echo "---------------------------------------------"
    local jumpInput
    read -rp "请选择模式 [1-2] (直接回车默认跳跃模式): " jumpInput
    jumpInput=${jumpInput:-2}

    if [[ $jumpInput == 2 ]]; then
        while true; do
            local p_start_msg="设置起始端口: "
            [[ -n "$old_first" ]] && p_start_msg="设置起始端口 [当前: ${old_first}, 回车不修改]: "
            read -rp "$p_start_msg" firstport
            firstport=${firstport:-$old_first}

            local p_end_msg="设置结束端口: "
            [[ -n "$old_end" ]] && p_end_msg="设置结束端口 [当前: ${old_end}, 回车不修改]: "
            read -rp "$p_end_msg" endport
            endport=${endport:-$old_end}

            if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then 
                break
            else 
                error "输入无效，起始端口必须小于末尾端口且不为空！"
                old_first="" old_end=""
            fi
        done

        iptables -t nat -N "HY2_JUMP_${instance}" 2>/dev/null || true
        iptables -t nat -A "HY2_JUMP_${instance}" -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
        iptables -t nat -I PREROUTING -j "HY2_JUMP_${instance}"
        
        ip6tables -t nat -N "HY2_JUMP_${instance}" 2>/dev/null || true
        ip6tables -t nat -A "HY2_JUMP_${instance}" -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
        ip6tables -t nat -I PREROUTING -j "HY2_JUMP_${instance}"

        if has_command netfilter-persistent; then command netfilter-persistent save >/dev/null 2>&1 || true; fi
        info "已成功下发隔离型端口跳跃规则: $firstport-$endport -> $port"
    else
        firstport="" && endport=""
    fi
}

print_node_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.yaml"
    local hy_dir="${HY_DIR_BASE}/${instance}"
    if [ ! -f "$conf_file" ]; then return; fi

    local vps_ip=$(get_public_ip)
    local main_port=$(grep -E '^listen:' "$conf_file" | awk -F ':' '{print $3}' | tr -d ' ')
    local auth_pwd=$(grep -E '^\s*password:' "$conf_file" | awk '{print $2}' | tr -d '"'\' || true)
    local masquerade_url=$(grep -E '^\s*url:' "$conf_file" | awk '{print $2}' | tr -d '"'\' || true)
    local hostname=$(hostname -s 2>/dev/null || echo "Xray")

  

    # 动态检测 SNI
    local current_sni="$EVAL_DOMAIN"
    if [[ -z "$current_sni" && -f "$hy_dir/hy-client.yaml" ]]; then
        current_sni=$(grep -E '^\s*sni:' "$hy_dir/hy-client.yaml" | awk '{print $2}' | tr -d '"'\' || true)
    fi
    current_sni=${current_sni:-"www.bing.com"}

    local skip_cert="false"
    [[ "$current_sni" == "www.bing.com" ]] && skip_cert="true"

    local jump_range="无 (单端口)"
    if [[ -f "$hy_dir/hy-client.yaml" ]]; then
        local found_range=$(grep -E '^server:' "$hy_dir/hy-client.yaml" | awk -F ',' '{print $2}' | tr -d ' ')
        [[ -n "$found_range" ]] && jump_range="$found_range"
    fi

    echo -e "\n${GREEN}== Hysteria 2 实例${RESET}${YELLOW} [ ${instance} ]${RESET} ${GREEN}配置详情 ==${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}Hysteria 2 (QUIC UDP)${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} $vps_ip"
    echo -e "${GREEN}监听主端口   :${RESET} $main_port"
    echo -e "${GREEN}端口跳跃范围 :${RESET} $jump_range"
    echo -e "${GREEN}验证鉴权密码 :${RESET} $auth_pwd"
    echo -e "${GREEN}伪装 SNI 域名:${RESET} $current_sni"
    echo -e "${GREEN}后端伪装站点 :${RESET} $masquerade_url"
    echo -e "${GREEN}配置文件路径 :${RESET} $conf_file"
    echo -e "${GREEN}--------------------------------------------${RESET}"
    if [[ -f "$hy_dir/url.txt" ]]; then
        echo -e "${GREEN}👉 标准通用分享链接:${RESET}"
        echo -e "${YELLOW}$(cat "$hy_dir/url.txt")${RESET}"
        echo ""
        echo -e "${GREEN}👉 Surge 专属配置格式:${RESET}"
        echo -e "${YELLOW}${hostname}-${instance}-Hy2 = hysteria2, ${vps_ip}, ${main_port}, password=${auth_pwd}, skip-cert-verify=${skip_cert}, sni=${current_sni}${RESET}"
    fi
    echo ""
}

write_and_show_config() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.yaml"
    local hy_dir="${HY_DIR_BASE}/${instance}"
    local HOSTNAME=$(hostname -s | sed 's/ /_/g')
    local vps_ip=$(get_public_ip)

    local is_insecure="0" yaml_insecure="false"
    if [[ "$EVAL_DOMAIN" == "www.bing.com" ]]; then
        is_insecure="1" yaml_insecure="true"
    fi

    cat << EOF > "$conf_file"
listen: :$port
tls:
  cert: $EVAL_CERT_PATH
  key: $EVAL_KEY_PATH
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
auth:
  type: password
  password: $auth_pwd
masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    local last_port=$port
    [[ -n "${firstport}" && -n "${endport}" ]] && last_port="$port,$firstport-$endport"
    local last_ip="$vps_ip"
    [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

    mkdir -p "$hy_dir"
    cat << EOF > "$hy_dir/hy-client.yaml"
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $EVAL_DOMAIN
  insecure: $yaml_insecure
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
fastOpen: true
socks5:
  listen: 127.0.0.1:5678
transport:
  udp:
    hopInterval: 30s 
EOF

    cat << EOF > "$hy_dir/url.txt"
hysteria2://$auth_pwd@$last_ip:$port?insecure=${is_insecure}&sni=$EVAL_DOMAIN#$HOSTNAME-hy-${instance}
EOF

    local inst_data_dir="${DATA_BASE_DIR}/${instance}"
    install -m 0750 -o hysteria -g hysteria -d "$inst_data_dir"
    chown -R hysteria:hysteria "$conf_file" 2>/dev/null || true
    register_instance "$instance"

    systemctl daemon-reload
    systemctl enable "hysteria-server@${instance}" >/dev/null 2>&1 || true
    systemctl restart "hysteria-server@${instance}" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "hysteria-server@${instance}" 2>/dev/null; then
        print_node_summary "$instance"
    else
        error "实例服务下发完成，但拉起响应失败。请通过菜单 [8] 排查系统滚动日志。"
    fi
}

insthysteria() {
    local mode="${1:-new}"
    check_environment
    
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    
    if ! has_command apt; then
        if has_command yum || has_command dnf; then install_software "iptables-services"; fi
    else
        install_software "iptables-persistent netfilter-persistent"
    fi

    if [[ ! -f "$INSTALL_BIN" ]]; then
        echo -e "${YELLOW}全局引擎内核缺失，准备同步拉取核心组件...${RESET}"
        local latest_version=$(get_latest_version)
        [[ -z "$latest_version" ]] && echo -e "${RED}无法获取云端最新版本！${RESET}" && return 1
        local _tmpfile=$(mktemp)
        download_hysteria "$latest_version" "$_tmpfile" || return 1
        install -Dm755 "$_tmpfile" "$INSTALL_BIN"
        rm -f "$_tmpfile"
    fi

    if ! is_user_exists "hysteria"; then
        useradd -r -d "$DATA_BASE_DIR" -m -s /usr/sbin/nologin hysteria >/dev/null 2>&1 || true
    fi
    write_systemd_template

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.yaml"
    if [[ "$mode" == "new" && -f "$conf_file" ]]; then
        echo -e "${YELLOW}[WARN]检测到该实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
        read -r -p "$(echo -e "${GREEN}是否强行完全覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    if [[ "$mode" == "edit" ]]; then
        echo -e "\n${GREEN}==== [正在修改实例参数: ${CURRENT_INSTANCE}] ====${RESET}"
        local old_pwd=$(grep -E '^\s*password:' "$conf_file" | awk '{print $2}' | tr -d '"'\' || true)
        local old_site=$(grep -E '^\s*url:' "$conf_file" | awk '{print $2}' | sed 's#https://##' | tr -d '"'\' || true)
    fi

    inst_cert "$CURRENT_INSTANCE" || return 1
    inst_port "$CURRENT_INSTANCE"

    if [[ "$mode" == "edit" ]]; then
        read -rp "配置鉴权验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
        auth_pwd=${auth_pwd:-$old_pwd}
        read -rp "配置伪装网站地址 [当前: ${old_site}, 回车不修改]: " proxysite
        proxysite=${proxysite:-$old_site}
    else
        read -rp "设置验证密码 (回车分配高强度随机密钥): " auth_pwd
        auth_pwd=${auth_pwd:-$(generate_random_password)}
        read -rp "设置伪装网站域名 (默认: en.snu.ac.kr): " proxysite
        proxysite=${proxysite:-"en.snu.ac.kr"}
    fi

    write_and_show_config "$CURRENT_INSTANCE"
}

unsthysteria() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    read -r -p "$(echo -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    systemctl stop "hysteria-server@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "hysteria-server@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    
    iptables -t nat -F "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    iptables -t nat -D PREROUTING -j "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    iptables -t nat -X "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -F "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -D PREROUTING -j "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -X "HY2_JUMP_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    if has_command netfilter-persistent; then command netfilter-persistent save >/dev/null 2>&1 || true; fi

    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.yaml"
    rm -f "${BASE_DIR}/server_${CURRENT_INSTANCE}.crt" "${BASE_DIR}/server_${CURRENT_INSTANCE}.key"
    rm -rf "${DATA_BASE_DIR}/${CURRENT_INSTANCE}" "${HY_DIR_BASE}/${CURRENT_INSTANCE}"

    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}矩阵实例 [ ${CURRENT_INSTANCE} ] 彻底安全移除。${RESET}"

    sync_registry
    if [ ! -s "$REGISTRY_FILE" ]; then
        echo -e "${GREEN}检测到矩阵内已无任何活跃节点，深度自动卸载全系统共享组件...${RESET}"
        rm -f /etc/systemd/system/hysteria-server@.service
        rm -f "$INSTALL_BIN"
        rm -rf "$BASE_DIR" "$DATA_BASE_DIR" "$HY_DIR_BASE"
        userdel hysteria >/dev/null 2>&1 || true
        systemctl daemon-reload
        echo -e "${GREEN}全系统宿主机残留已深度彻底清洗清除。${RESET}"
        CURRENT_INSTANCE="hy2"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [Hysteria 2 多开实例中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    sync_registry
    local count=0
    local -a instance_list=()

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.yaml"
            [ -f "$c_file" ] || continue

            count=$((count + 1))
            instance_list[$count]="$name"
            
            local port_num=$(grep -E '^listen:' "$c_file" | awk -F ':' '{print $3}' | tr -d ' ')
            local status_str="${RED}已停止${RESET}"
            if systemctl is-active --quiet "hysteria-server@${name}"; then status_str="${GREEN}运行中${RESET}"; fi
            echo -e " ${CYAN}[ ${count} ] ->${GREEN} 实例名: ${YELLOW}${name}${RESET} ${GREEN}[绑定端口: ${port_num} | 运行状态: ${status_str}]${GREEN}"
        done < "$REGISTRY_FILE"
    fi

    if [ "$count" -eq 0 ]; then echo -e " ${YELLOW}(当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)${RESET}"; fi
    
    echo ""
    echo -e "${GREEN}👉 输入已有实例前面的【数字编号】快速切换管理目标${RESET}"
    echo -e "${GREEN}👉 或者直接输入一个【全新的英文别名】来新建独立多开实例${RESET}"
    echo -ne "${YELLOW}请输入选择或名字: ${RESET}"
    read -r input_val || true
    [[ -z "$input_val" ]] && return

    if [[ "$input_val" =~ ^[0-9]+$ ]]; then
        if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
            CURRENT_INSTANCE="${instance_list[$input_val]}"
            echo -e "${GREEN}操作焦点成功切为已有实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        else echo -e "${RED}编号超出可用范围！${RESET}"; fi
    else
        if [[ "$input_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            CURRENT_INSTANCE="$input_val"
            echo -e "${GREEN}成功锁定并创建新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET}${GREEN} (请在主菜单选择 [1] 下发部署服务)${RESET}"
        else echo -e "${RED}命名不规范，仅限使用英文字母、数字、中划线和下划线！${RESET}"; fi
    fi
}

showconf() {
    print_node_summary "$CURRENT_INSTANCE"
}

menu() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请切换至 root 用户运行此面板脚本。${RESET}" && exit 1
    check_environment

    while true; do
        clear
        local status=$(get_hy_status)
        local version=$(get_installed_version)
        local port_show=$(get_current_port_display)

        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}     ◈  Hysteria 2  多实例管理面板  ◈      ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        echo -e "${GREEN}目标实例端口 :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}服务活跃状态 :${RESET} $status"
        echo -e "${GREEN}核心共享引擎 :${RESET} ${YELLOW}${version}${RESET}"
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
        echo -e "${GREEN}10. 管理实例     ${YELLOW}← 添加/切换节点${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}===========================================${RESET}"

        local choice=""
        read -r -p $'\033[32m选择操作序号: \033[0m' choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) insthysteria "new"; pause ;;
            2) 
                local latest_version=$(get_latest_version)
                if [[ -n "$latest_version" ]]; then
                    local _tmpfile=$(mktemp)
                    if download_hysteria "$latest_version" "$_tmpfile"; then
                        install -Dm755 "$_tmpfile" "$INSTALL_BIN" && rm -f "$_tmpfile"
                        echo -e "${GREEN}[OK]二进制核心覆盖升级完毕，请视情况手动重启各运行中的实例。${RESET}"
                    fi
                else echo -e "${GREEN}获取云端版本号失败。${RESET}"; fi
                pause ;;
            3) unsthysteria; pause ;;
            4) insthysteria "edit"; pause ;;
            5) systemctl start "hysteria-server@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]启动成功${RESET}" ; pause ;;
            6) systemctl stop "hysteria-server@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]停止成功${RESET}" ; pause ;;
            7) systemctl restart "hysteria-server@${CURRENT_INSTANCE}" && echo -e "${GREEN}[OK]重启完毕${RESET}" ; pause ;;
            8) 
                echo -e "${YELLOW}正在调取该实例实时滚动日志 (输入 q 或 Ctrl+C 退出返回):${RESET}\n"
                journalctl -u "hysteria-server@${CURRENT_INSTANCE}" -n 50 -f || true
                ;;
            9) showconf; pause ;;
            10) menu_switch_matrix ;;
            0) clear; exit 0 ;;
            *) echo -e "${YELLOW}[警告] 输入未知操作序号！${RESET}"; sleep 0.5 ;;
        esac
    done
}

menu "$@"
