#!/usr/bin/env bash
#
# sing-box Hysteria 2 多实例管理面板 [Alpine 专属增强版]
# SPDX-License-Identifier: MIT
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
export TEMPLATE_NAME="sing-box-hy2"
export BASE_DIR="/etc/mo-sb-hy2"
export INSTALL_BIN="/usr/local/bin/sing-box-hy2"
export DATA_BASE_DIR="/var/lib/sing-box-hy2"
export HY_DIR_BASE="/root/proxynode/sb-hy2"
export REGISTRY_FILE="${BASE_DIR}/.instances.env"
export OPENRC_TEMPLATE_PATH="/etc/init.d/sing-box-hy2"

CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "hy2")"
TMP_DIR=$(mktemp -d -t sb-hy2.XXXXXX)

# 颜色标准规范
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# GITHUB 代理列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
ok() { echo -e "${GREEN}[成功] $*${RESET}" >&2; }
pause() { echo; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制面板...${RESET}")" || true; echo; }

cleanup() { [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

generate_random_password() {
    dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

is_alpine() { [[ -f /etc/alpine-release ]]; }

install_packages() {
    # 建立核心命令依赖列表
    local req_cmds=("curl" "wget" "tar" "openssl" "rc-service" "ip" "jq" "grep" "sed" "coreutils" "dig" "iptables" "socat")
    local missing_cmds=()

    for cmd in "${req_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    # 只有当存在缺失的命令时，才执行 apk 安装，否则直接跳过
    if [ ${#missing_cmds[@]} -ne 0 ]; then
        info "检测到系统缺少必要组件 [ ${missing_cmds[*]} ]，正在安装..."
        apk update
        # 映射一些包名和命令名不一致的情况
        apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools iptables ip6tables gcompat socat python3
        
        if [[ -f /etc/init.d/iptables ]]; then
            rc-update add iptables default >/dev/null 2>&1 || true
            rc-service iptables start >/dev/null 2>&1 || true
        fi
        if [[ -f /etc/init.d/ip6tables ]]; then
            rc-update add ip6tables default >/dev/null 2>&1 || true
            rc-service ip6tables start >/dev/null 2>&1 || true
        fi
    fi
}
create_user() {
    getent group "singbox-hy2" &>/dev/null || addgroup -S "singbox-hy2"
    id "singbox-hy2" &>/dev/null || adduser -S -D -H -G "singbox-hy2" -s /sbin/nologin "singbox-hy2"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        *) error "不支持当前架构: $(uname -m)"; exit 8 ;;
    esac
}

check_environment() {
    if ! is_alpine; then
        error "本脚本仅支持 Alpine Linux 系统。"
        exit 95
    fi
    install_packages
    create_user
}

get_installed_version() {
    if [[ -f "$INSTALL_BIN" ]]; then
        "$INSTALL_BIN" version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知版本"
    else echo "未安装核心"; fi
}

# =========================================================
# 注册表与实例发现控制 (矩阵核心)
# =========================================================
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
    for f in "${BASE_DIR}"/config_*.json; do
        [ -e "$f" ] || continue
        local name=$(basename "$f" | sed 's/^config_//;s/\.json$//')
        if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
    done
    mv -f "$temp_reg" "$REGISTRY_FILE"
}

write_openrc_template() {
    # 写入基础服务模板
    cat << 'EOF' > "$OPENRC_TEMPLATE_PATH"
#!/sbin/openrc-run

# 动态获取当前软链接的服务后缀名作为实例名
INSTANCE_NAME="${RC_SVCNAME#sing-box-hy2.}"
if [ "$INSTANCE_NAME" = "sing-box-hy2" ]; then
    eerror "请勿直接运行主模板，必须通过多实例软链接调用！"
    exit 1
fi

name="sing-box-hy2 (${INSTANCE_NAME})"
description="sing-box Hysteria 2 OpenRC Isolated Service - Instance: ${INSTANCE_NAME}"
cfgfile="/etc/mo-sb-hy2/config_${INSTANCE_NAME}.json"
logfile="/var/log/sing-box-hy2_${INSTANCE_NAME}.log"
command="/usr/local/bin/sing-box-hy2"
command_args="run -c ${cfgfile}"

depend() {
    need net
    after iptables ip6tables firewall
}

start_pre() {
    if [ ! -f "$cfgfile" ]; then
        eerror "Configuration file $cfgfile missing!"
        return 1
    fi
    
    touch "$logfile"
    chown singbox-hy2:singbox-hy2 "$logfile"
    chmod 644 "$logfile"
    
    command_background="yes"
    pidfile="/run/${RC_SVCNAME}.pid"
    
    output_log="$logfile"
    error_log="$logfile"
    
    local port
    port=$(jq -r '.inbounds[0].listen_port // 0' "$cfgfile" 2>/dev/null)
    if [ "$port" -lt 1024 ] && [ "$port" -ne 0 ]; then
        command_user="root:root"
    else
        command_user="singbox-hy2:singbox-hy2"
    fi
}
EOF
    chmod +x "$OPENRC_TEMPLATE_PATH"
}

# =========================================================
# 网络代理与云端核心交互
# =========================================================
request_github_api() {
    local path="$1"
    local response=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        if [[ -z "$proxy" ]]; then
            response=$(curl -fsSL --max-time 8 "https://api.github.com/${path}" 2>/dev/null || true)
        else
            response=$(curl -fsSL --max-time 8 "${proxy}https://api.github.com/${path}" 2>/dev/null || true)
        fi
        if [[ -n "$response" && "$response" != "null" ]]; then
            echo "$response" && return 0
        fi
    done
    return 1
}

get_latest_version() {
    info "正在从 GitHub 获取 sing-box 最新版本号..."
    local latest_v=""
    local api_res
    if api_res=$(request_github_api "repos/SagerNet/sing-box/releases/latest"); then
        latest_v=$(echo "$api_res" | jq -r .tag_name 2>/dev/null | sed 's/^v//')
    fi
    if [[ -z "$latest_v" || "$latest_v" == "null" ]]; then
        for proxy in "${GITHUB_PROXY[@]}"; do
            latest_v=$(curl -fsSL --max-time 8 "${proxy}https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oE 'releases/tag/v[0-9.]+' | head -n1 | sed 's|releases/tag/v||' || true)
            [[ -n "$latest_v" ]] && break
        done
    fi
    if [[ -n "$latest_v" ]]; then
        SINGBOX_VERSION="$latest_v"
        info "成功获取最新版本: v$SINGBOX_VERSION"
    else
        SINGBOX_VERSION="1.13.12"
        warn "无法获取最新版本，将使用保底版本: v$SINGBOX_VERSION"
    fi
}

download_core() {
    local arch url
    arch=$(detect_arch)
    get_latest_version
    local download_success=false
    cd "$TMP_DIR"
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        url=$(printf '%ssing-box-%s-linux-%s.tar.gz' "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/" "$SINGBOX_VERSION" "$arch")
        [[ -n "$proxy" ]] && url="${proxy}${url}"
        info "正在通过代理 [ ${proxy:-直连保底} ] 下载官方核心 sing-box v$SINGBOX_VERSION..."
        if wget -O sing-box.tar.gz -q "$url" || curl -fsSL -o sing-box.tar.gz "$url"; then
            if [[ -s sing-box.tar.gz ]]; then download_success=true; break; fi
        fi
    done

    if [[ "$download_success" = false ]]; then
        error "所有渠道均下载核心文件失败，请检查网络。"
        return 1
    fi
    
    tar -xzf sing-box.tar.gz -C "$TMP_DIR"
    local extracted
    extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
    [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
    
    install -m 755 "$extracted" "$INSTALL_BIN"
    info "sing-box 共享引擎内核释放完毕。"
    return 0
}

# =========================================================
# 端口流控与安全隔离型 OpenRC 规则下发
# =========================================================
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
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
    if rc-service "sing-box-hy2.${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_current_port_display() {
    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
    local hy_dir="${HY_DIR_BASE}/${CURRENT_INSTANCE}"
    if [[ -f "$conf_file" ]]; then
        local main_port
        main_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file" 2>/dev/null)
        if [[ -f "${BASE_DIR}/hopping_${CURRENT_INSTANCE}.txt" ]]; then
            local jump_range=$(cat "${BASE_DIR}/hopping_${CURRENT_INSTANCE}.txt")
            [[ -n "$jump_range" ]] && echo "${main_port} [跳跃: ${jump_range}]" && return
        fi
        echo "${main_port:- -}"
    else echo "实例未初始化"; fi
}

fix_external_cert_permission() {
    local cert="$1" key="$2"
    if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
        error "拒绝: 检测到您的证书位于 /root/ 目录下！非 root 运行用户无权穿透读取。"
        return 1
    fi
    local cert_dir=$(dirname "$cert")
    chmod +x "$cert_dir" 2>/dev/null || true
    chmod 644 "$cert" "$key" 2>/dev/null || true
    return 0
}

inst_cert() {
    local instance="$1"
    local cert_path="${BASE_DIR}/server_${instance}.crt"
    local key_path="${BASE_DIR}/server_${instance}.key"
    local conf_file="${BASE_DIR}/config_${instance}.json"

    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        echo "---------------------------------------------"
        echo -e "${YELLOW}[提示] 检测到实例 [ ${instance} ] 已有历史证书文件。${RESET}"
        read -rp "是否要重新更改证书配置？[y/N] (直接回车保持不变): " cert_change_choice
        cert_change_choice=${cert_change_choice:-n}
        if [[ ! "$cert_change_choice" =~ ^[Yy]$ ]]; then
            info "保持原有证书配置不变。"
            local old_sni="www.bing.com"
            [[ -f "$conf_file" ]] && old_sni=$(jq -r '.inbounds[0].tls.server_name // "www.bing.com"' "$conf_file")
            export EVAL_CERT_PATH="$cert_path"
            export EVAL_KEY_PATH="$key_path"
            export EVAL_DOMAIN="${old_sni}"
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
            local random_email="sb_hy2_$(date +%s | cut -c 5-10)@gmail.com"
            info "正在通过官方通道一键安装 acme.sh ..."
            # 核心修复：改回标准的 --install 并强制指定 --home 目录，添加 --nocron 适配 Alpine
            curl -fsSL https://get.acme.sh | sh -s -- --install \
                --home /root/.acme.sh \
                --email "$random_email" \
                --nocron
        fi
        
        # 兜底验证安装结果
        if [[ ! -f "$acme_cmd" ]]; then
            error "acme.sh 安装失败，请检查机器的公网网络是否能正常连接 GitHub！"
            return 1
        fi
        
        "$acme_cmd" --set-default-ca --server letsencrypt
        
        # 核心适配：将 systemctl 替换为 Alpine 的 OpenRC 多实例服务重启命令
        local reload_cmd="/sbin/rc-service sing-box-hy2.${instance} restart"
        
        info "正在向 Let's Encrypt 申请证书..."
        if [[ "$vps_ip" =~ ":" ]]; then
            "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
        else
            "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
        fi

        if "$acme_cmd" --install-cert -d "${domain}" \
            --key-file "$key_path" \
            --fullchain-file "$cert_path" \
            --ecc \
            --reloadcmd "$reload_cmd"; then
            hy_domain=$domain
            info "Acme 独立实例证书部署成功！"
        else
            error "Acme 申请失败，自动切换回自签模式。"
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
                fix_external_cert_permission "$user_cert" "$user_key" || continue
                ln -sf "$user_cert" "$cert_path"
                ln -sf "$user_key" "$key_path"
                break
            else 
                error "路径未找到，请重新输入！"
            fi
        done
    fi

    if [[ $certInput == 1 ]]; then
        info "将使用必应自签证书作为 Hysteria 2 外壳的节点证书..."
        rm -f "$cert_path" "$key_path"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        hy_domain="www.bing.com"
    fi

    chown -R singbox-hy2:singbox-hy2 "$cert_path" "$key_path" 2>/dev/null || true
    export EVAL_CERT_PATH="$cert_path"
    export EVAL_KEY_PATH="$key_path"
    export EVAL_DOMAIN="$hy_domain"
}

inst_port() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.json"
    local default_port=""
    local old_first="" old_end=""

    [[ -f "$conf_file" ]] && default_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file" 2>/dev/null)
    if [[ -f "${BASE_DIR}/hopping_${instance}.txt" ]]; then
        local old_range=$(cat "${BASE_DIR}/hopping_${instance}.txt")
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

    # 清理当前专属实例历史旧防火墙链条
    iptables -t nat -F "SB_HY2_${instance}" >/dev/null 2>&1 || true
    iptables -t nat -D PREROUTING -j "SB_HY2_${instance}" >/dev/null 2>&1 || true
    iptables -t nat -X "SB_HY2_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -F "SB_HY2_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -D PREROUTING -j "SB_HY2_${instance}" >/dev/null 2>&1 || true
    ip6tables -t nat -X "SB_HY2_${instance}" >/dev/null 2>&1 || true

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

        # 针对当前实例下发独立隔离自定义子链
        iptables -t nat -N "SB_HY2_${instance}" 2>/dev/null || true
        iptables -t nat -A "SB_HY2_${instance}" -p udp --dport "$firstport:$endport" -j REDIRECT --to-ports "$port"
        iptables -t nat -I PREROUTING -j "SB_HY2_${instance}"
        
        ip6tables -t nat -N "SB_HY2_${instance}" 2>/dev/null || true
        ip6tables -t nat -A "SB_HY2_${instance}" -p udp --dport "$firstport:$endport" -j REDIRECT --to-ports "$port"
        ip6tables -t nat -I PREROUTING -j "SB_HY2_${instance}"

        if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
        if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi
        echo "$firstport-$endport" > "${BASE_DIR}/hopping_${instance}.txt"
        info "已成功下发隔离型端口跳跃规则: $firstport-$endport -> $port"
    else
        rm -f "${BASE_DIR}/hopping_${instance}.txt"
        firstport="" && endport=""
    fi
}

print_node_summary() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.json"
    local hy_dir="${HY_DIR_BASE}/${instance}"
    if [ ! -f "$conf_file" ]; then return; fi

    local vps_ip=$(get_public_ip)
    local main_port=$(jq -r '.inbounds[0].listen_port' "$conf_file")
    local auth_pwd=$(jq -r '.inbounds[0].users[0].password' "$conf_file")
    local current_sni=$(jq -r '.inbounds[0].tls.server_name' "$conf_file")
    local hostname=$(hostname -s 2>/dev/null || echo "Alpine")

    local is_insecure="false"
    [[ "$current_sni" == "www.bing.com" ]] && is_insecure="true"

    local jump_range="无 (单端口)"
    [[ -f "${BASE_DIR}/hopping_${instance}.txt" ]] && jump_range=$(cat "${BASE_DIR}/hopping_${instance}.txt")

    local last_ip="$vps_ip"
    [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

    echo -e "\n${GREEN}== sing-box Hy2 实例${RESET}${YELLOW} [ ${instance} ]${RESET} ${GREEN}配置详情 ==${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}Hysteria 2 (sing-box 内核)${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} $vps_ip"
    echo -e "${GREEN}监听主端口   :${RESET} $main_port"
    echo -e "${GREEN}端口跳跃范围 :${RESET} $jump_range"
    echo -e "${GREEN}验证鉴权密码 :${RESET} $auth_pwd"
    echo -e "${GREEN}伪装 SNI 域名:${RESET} $current_sni"
    echo -e "${GREEN}配置文件路径 :${RESET} $conf_file"
    echo -e "${GREEN}--------------------------------------------${RESET}"
    if [[ -f "$hy_dir/url.txt" ]]; then
        echo -e "${GREEN}👉 标准通用分享链接:${RESET}"
        echo -e "${YELLOW}$(cat "$hy_dir/url.txt")${RESET}"
        echo ""
        echo -e "${GREEN}👉 Surge 专属配置格式:${RESET}"
        echo -e "${YELLOW}${hostname}-${instance}-Hy2 = hysteria2, ${vps_ip}, ${main_port}, password=${auth_pwd}, skip-cert-verify=${is_insecure}, sni=${current_sni}${RESET}"
    fi
    echo ""
}

write_and_show_config() {
    local instance="$1"
    local conf_file="${BASE_DIR}/config_${instance}.json"
    local hy_dir="${HY_DIR_BASE}/${instance}"
    local HOSTNAME=$(hostname -s | sed 's/ /_/g')
    local vps_ip=$(get_public_ip)
    local log_path="/var/log/sing-box-hy2_${instance}.log"

    local is_insecure="0"
    if [[ "$EVAL_DOMAIN" == "www.bing.com" ]]; then is_insecure="1"; fi

    cat << EOF > "$conf_file"
{
  "log": {
    "level": "info",
    "output": "$log_path",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in-${instance}",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "password": "$auth_pwd"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "server_name": "$EVAL_DOMAIN",
        "certificate_path": "$EVAL_CERT_PATH",
        "key_path": "$EVAL_KEY_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    local last_port=$port
    if [[ -f "${BASE_DIR}/hopping_${instance}.txt" ]]; then
        last_port=$(cat "${BASE_DIR}/hopping_${instance}.txt")
    fi
    local last_ip="$vps_ip"
    [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

    mkdir -p "$hy_dir"
    cat << EOF > "$hy_dir/url.txt"
hysteria2://$auth_pwd@$last_ip:$port?insecure=${is_insecure}&sni=$EVAL_DOMAIN#$HOSTNAME-sbhy2-${instance}
EOF

    chmod 640 "$conf_file"
    chown -R singbox-hy2:singbox-hy2 "$BASE_DIR"
    register_instance "$instance"

    # OpenRC 通过创建独立服务命名的软链接实现多实例运行机制
    local instance_service="/etc/init.d/sing-box-hy2.${instance}"
    if [[ ! -L "$instance_service" ]]; then
        ln -sf "$OPENRC_TEMPLATE_PATH" "$instance_service"
    fi

    rc-update add "sing-box-hy2.${instance}" default >/dev/null 2>&1 || true
    rc-service "sing-box-hy2.${instance}" restart >/dev/null 2>&1 || true

    if rc-service "sing-box-hy2.${instance}" status 2>/dev/null | grep -q "started"; then
        print_node_summary "$instance"
    else
        error "实例服务下发完成，但拉起响应失败。请通过菜单 [8] 排查错误日志。"
    fi
}

insthysteria() {
    local mode="${1:-new}"
    check_environment
    
    [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
    write_openrc_template

    if [[ ! -f "$INSTALL_BIN" ]]; then
        echo -e "${YELLOW}全局引擎内核缺失，准备同步拉取核心组件...${RESET}"
        download_core || return 1
    fi

    local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
    if [[ "$mode" == "new" && -f "$conf_file" ]]; then
        echo -e "${YELLOW}[WARN]检测到该实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
        read -r -p "$(echo -e "${GREEN}是否强行覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    if [[ "$mode" == "edit" ]]; then
        echo -e "\n${GREEN}==== [正在修改实例参数: ${CURRENT_INSTANCE}] ====${RESET}"
        local old_pwd=$(jq -r '.inbounds[0].users[0].password // empty' "$conf_file")
    fi

    inst_cert "$CURRENT_INSTANCE" || return 1
    inst_port "$CURRENT_INSTANCE"

    if [[ "$mode" == "edit" ]]; then
        read -rp "配置鉴权验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
        auth_pwd=${auth_pwd:-$old_pwd}
    else
        read -rp "设置验证密码 (回车分配高强度随机密钥): " auth_pwd
        auth_pwd=${auth_pwd:-$(generate_random_password)}
    fi

    write_and_show_config "$CURRENT_INSTANCE"
}

unsthysteria() {
    echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前控制聚焦的 [ ${CURRENT_INSTANCE} ] 独立服务。${RESET}"
    read -r -p "$(echo -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    rc-service "sing-box-hy2.${CURRENT_INSTANCE}" stop >/dev/null 2>&1 || true
    rc-update del "sing-box-hy2.${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/sing-box-hy2.${CURRENT_INSTANCE}"
    
    iptables -t nat -F "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    iptables -t nat -D PREROUTING -j "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    iptables -t nat -X "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -F "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -D PREROUTING -j "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    ip6tables -t nat -X "SB_HY2_${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
    if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
    if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi

    rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.json" "${BASE_DIR}/hopping_${CURRENT_INSTANCE}.txt"
    rm -f "${BASE_DIR}/server_${CURRENT_INSTANCE}.crt" "${BASE_DIR}/server_${CURRENT_INSTANCE}.key"
    rm -f "/var/log/sing-box-hy2_${CURRENT_INSTANCE}.log"
    rm -rf "${HY_DIR_BASE}/${CURRENT_INSTANCE}"

    unregister_instance "$CURRENT_INSTANCE"
    echo -e "${GREEN}矩阵实例 [ ${CURRENT_INSTANCE} ] 彻底安全移除。${RESET}"

    sync_registry
    if [ ! -s "$REGISTRY_FILE" ]; then
        echo -e "${GREEN}检测到矩阵内已无任何活跃节点，深度自动卸载全系统共享组件...${RESET}"
        rm -f "$OPENRC_TEMPLATE_PATH" "$INSTALL_BIN"
        rm -rf "$BASE_DIR" "$HY_DIR_BASE"
        echo -e "${GREEN}全系统宿主机残留已深度彻底清洗清除。${RESET}"
        CURRENT_INSTANCE="hy2"
    fi
}

menu_switch_matrix() {
    echo -e "\n${GREEN}==== [sing-box Hysteria 2 多开实例中心] ====${RESET}"
    echo -e "${GREEN}当前操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}当前独立实例列表:${RESET}"

    sync_registry
    local count=0
    local -a instance_list=()

    if [ -f "$REGISTRY_FILE" ]; then
        while IFS= read -r name || [ -n "$name" ]; do
            [ -z "$name" ] && continue
            local c_file="${BASE_DIR}/config_${name}.json"
            [ -f "$c_file" ] || continue

            count=$((count + 1))
            instance_list[$count]="$name"
            
            local port_num=$(jq -r '.inbounds[0].listen_port // empty' "$c_file")
            local status_str="${RED}已停止${RESET}"
            if rc-service "sing-box-hy2.${name}" status 2>/dev/null | grep -q "started"; then 
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

# =========================================================
# 7. 面板交互菜单 
# =========================================================
menu() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请切换至 root 用户运行此面板脚本。${RESET}" && exit 1
    check_environment

    while true; do
        clear
        local status=$(get_hy_status)
        local version=$(get_installed_version)
        local port_show=$(get_current_port_display)

        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}      ◈ sing-box Hy2 多实例面板 ◈          ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
        echo -e "${GREEN}目标实例端口 :${RESET} ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}服务活跃状态 :${RESET} $status"
        echo -e "${GREEN}共享内核版本 :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN} 1. 安装当前实例${RESET}"
        echo -e "${GREEN} 2. 更新共享内核程序${RESET}"
        echo -e "${GREEN} 3. 卸载当前实例${RESET}"
        echo -e "${GREEN} 4. 修改当前实例配置${RESET}"
        echo -e "${GREEN} 5. 启动当前实例${RESET}"
        echo -e "${GREEN} 6. 停止当前实例${RESET}"
        echo -e "${GREEN} 7. 重启当前实例${RESET}"
        echo -e "${GREEN} 8. 查看当前实例日志${RESET}"
        echo -e "${GREEN} 9. 查看当前实例配置${RESET}"
        echo -e "${GREEN}10. 管理多开实例    ${YELLOW}← 添加/切换节点${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}===========================================${RESET}"

        local choice=""
        read -r -p $'\033[32m选择操作序号: \033[0m' choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) insthysteria "new"; pause ;;
            2) 
                if download_core; then
                    echo -e "${GREEN}[OK] 引擎内核覆盖升级完毕，各运行实例将在重启后生效。${RESET}"
                fi
                pause ;;
            3) unsthysteria; pause ;;
            4) insthysteria "edit"; pause ;;
            5) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" start && echo -e "${GREEN}[OK]启动成功${RESET}" ; pause ;;
            6) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" stop && echo -e "${GREEN}[OK]停止成功${RESET}" ; pause ;;
            7) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" restart && echo -e "${GREEN}[OK]重启完毕${RESET}" ; pause ;;
            8) 
                local log_f="/var/log/sing-box-hy2_${CURRENT_INSTANCE}.log"
                if [[ -f "$log_f" ]]; then tail -n 50 "$log_f"; else warn "未发现实例运行日志。"; fi
                pause ;;
            9) showconf; pause ;;
            10) menu_switch_matrix ;;
            0) clear; exit 0 ;;
            *) error "输入未知操作序号！"; sleep 0.5 ;;
        esac
    done
}

menu "$@"
