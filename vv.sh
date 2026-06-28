#!/usr/bin/env bash
#
# sing-box Hysteria 2 [Alpine多实例矩阵版]
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly BINARY_PATH="/usr/local/bin/sing-box-hy2"
readonly BASE_DIR="/etc/sing-box-hy2"
readonly HY2_DIR_BASE="/root/proxynode/hy2"
readonly OPENRC_TEMPLATE_PATH="/etc/init.d/sing-box-hy2"
readonly RUN_USER="singbox-hy2"

# 注册表文件：持久化记录矩阵内所有活跃的实例名
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

# 默认控制的目标实例名称自动改成当前主机名
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
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
ok() { echo -e "${GREEN}[成功] $*${RESET}" >&2; }
pause() { echo; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回菜单...${RESET}")" || true; echo; }

cleanup() {
  [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

is_alpine() {
  [[ -f /etc/alpine-release ]]
}

install_packages() {
  info "正在刷新 Alpine 仓库并安装核心依赖..."
  apk update >/dev/null 2>&1 || true
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools iptables ip6tables gcompat socat python3
  
  if [[ -f /etc/init.d/iptables ]]; then
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-service iptables start >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/init.d/ip6tables ]]; then
    rc-update add ip6tables default >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
  fi
}

create_user() {
  getent group "$RUN_USER" &>/dev/null || addgroup -S "$RUN_USER"
  id "$RUN_USER" &>/dev/null || adduser -S -D -H -G "$RUN_USER" -s /sbin/nologin "$RUN_USER"
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
  # 确保父目录先存在
  [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"
  install_packages
  create_user
}

get_installed_version() {
  if [[ -f "$BINARY_PATH" ]]; then
    "$BINARY_PATH" version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知版本"
  else
    echo "未安装核心"
  fi
}

# =========================================================
# 2. 多实例矩阵持久化与内核注册表
# =========================================================
register_instance() {
  local name="$1"
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

# 动态多开 OpenRC 骨架脚本
write_openrc_template() {
  cat << 'EOF' > "$OPENRC_TEMPLATE_PATH"
#!/sbin/openrc-run

# 巧妙利用 OpenRC 实例软链接后缀名作为 %I 动态切分变量
INSTANCE="${RC_SVCNAME#sing-box-hy2.}"
if [ "$INSTANCE" = "sing-box-hy2" ]; then
    eerror "请勿直接运行主模板，必须通过实例软链接运行！"
    return 1
fi

name="sing-box-hy2.${INSTANCE}"
description="sing-box Hysteria 2 - Instance: ${INSTANCE}"
cfgfile="/etc/sing-box-hy2/config_${INSTANCE}.json"
logfile="/var/log/sing-box-hy2_${INSTANCE}.log"
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
# 3. 代理网络请求与下载核心
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
    warn "通过 API 获取最新版本失败，尝试备用网页匹配方案..."
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
      if [[ -s sing-box.tar.gz ]]; then download_success=true && break; fi
    fi
    warn "当前代理下载失败，正在尝试下一个..."
  done
  if [[ "$download_success" = false ]]; then
    error "所有代理及直连通道均下载核心文件失败，请检查网络后重试。"
    return 1
  fi
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted
  extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box-hy2 全局核心释放完毕。"
  return 0
}

# =========================================================
# 4. 防火墙路由控制 (隔离型独立链条)
# =========================================================
clear_old_iptables() {
  local instance="$1"
  info "正在清洁实例 [ ${instance} ] 的防火墙残留规则..."
  iptables -t nat -F "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -j "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  iptables -t nat -X "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  
  ip6tables -t nat -F "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  ip6tables -t nat -D PREROUTING -j "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  ip6tables -t nat -X "HY2_JUMP_${instance}" >/dev/null 2>&1 || true
  
  rm -f "${BASE_DIR}/hopping_${instance}.txt"
}

apply_new_iptables() {
  local instance="$1"
  local target_port="$2"
  local hop_file="${BASE_DIR}/hopping_${instance}.txt"
  
  if [[ -f "$hop_file" ]]; then
    local hop_val=$(cat "$hop_file")
    local start_p="${hop_val%-*}"
    local end_p="${hop_val#*-}"
    
    info "正在为实例 [ ${instance} ] 下发隔离型端口跳跃规则: UDP $start_p-$end_p => $target_port"
    
    iptables -t nat -N "HY2_JUMP_${instance}" 2>/dev/null || true
    iptables -t nat -A "HY2_JUMP_${instance}" -p udp --dport "${start_p}:${end_p}" -j REDIRECT --to-ports "$target_port"
    iptables -t nat -I PREROUTING -j "HY2_JUMP_${instance}"

    if [[ -f /etc/init.d/ip6tables ]]; then
      ip6tables -t nat -N "HY2_JUMP_${instance}" 2>/dev/null || true
      ip6tables -t nat -A "HY2_JUMP_${instance}" -p udp --dport "${start_p}:${end_p}" -j REDIRECT --to-ports "$target_port"
      ip6tables -t nat -I PREROUTING -j "HY2_JUMP_${instance}"
    fi
    
    if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
    if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi
  fi
}

# =========================================================
# 5. 网络辅助与状态打印
# =========================================================
get_public_ip() {
  local ip
  for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
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

get_hy2_status() {
  if rc-service "sing-box-hy2.${CURRENT_INSTANCE}" status 2>/dev/null | grep -q "started"; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

get_current_port_display() {
  local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  local hop_file="${BASE_DIR}/hopping_${CURRENT_INSTANCE}.txt"
  if [[ -f "$conf_file" ]]; then
    local main_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file" 2>/dev/null)
    local jump_range="无"
    [[ -f "$hop_file" ]] && jump_range=$(cat "$hop_file")
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [跳跃: ${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "子实例未初始化"; fi
}

# =========================================================
# 6. 证书与端口多实例隔离引导生成
# =========================================================
fix_external_cert_permission() {
  local cert="$1" key="$2"
  if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
    error "致命拒绝: 检测到您的证书位于 /root/ 目录下！非 root 运行用户无权穿透读取。"
    return 1
  fi
  local dir
  for file in "$cert" "$key"; do
    dir=$(dirname "$file")
    while [[ "$dir" != "/" && -n "$dir" ]]; do
      chmod o+x "$dir" 2>/dev/null || true
      dir=$(dirname "$dir")
    done
  done
  chmod 644 "$cert" "$key" 2>/dev/null || true
  return 0
}

inst_cert() {
  local instance="$1"
  mkdir -p "$BASE_DIR/certs"
  local cert_path="$BASE_DIR/certs/cert_${instance}.pem"
  local key_path="$BASE_DIR/certs/key_${instance}.pem"

  echo "---------------------------------------------"
  echo -e "实例 [ ${instance} ] 证书配置选择："
  echo -e " 1) 必应自签证书${YELLOW}（默认）${RESET} "
  echo -e " 2) Acme自动申请(需放行80端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  if [[ $certInput == 2 ]]; then
    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
    
    local acme_cmd="/root/.acme.sh/acme.sh"
    if [[ ! -f "$acme_cmd" ]]; then
      curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
    fi
    "$acme_cmd" --set-default-ca --server letsencrypt
    
    if [[ "$(get_public_ip)" =~ ":" ]]; then
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    else
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi
    
    local reload_cmd="rc-service sing-box-hy2.${instance} restart"
    if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc --reloadcmd "$reload_cmd"; then
      hy2_domain=$domain
    else
      error "Acme 证书申请失败，自动降级切换回自签模式。"
      certInput=1
    fi
  elif [[ $certInput == 3 ]]; then
    while true; do
      local user_cert user_key
      read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
      read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
      read -rp "请输入证书对应的域名: " hy2_domain
      if [[ -f "$user_cert" && -f "$user_key" ]]; then
        rm -f "$cert_path" "$key_path"
        if fix_external_cert_permission "$user_cert" "$user_key"; then
          ln -sf "$user_cert" "$cert_path"
          ln -sf "$user_key" "$key_path"
          break
        fi
      else error "找不到文件，请确认路径。"; fi
    done
  fi

  if [[ $certInput == 1 ]]; then
    rm -f "$cert_path" "$key_path"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    hy2_domain="www.bing.com"
    chmod 644 "$cert_path" "$key_path" || true
  fi

  chown -h ${RUN_USER}:${RUN_USER} "$cert_path" "$key_path" 2>/dev/null || true
  export EVAL_CERT_PATH="$cert_path"
  export EVAL_KEY_PATH="$key_path"
  export EVAL_DOMAIN="$hy2_domain"
}

inst_port() {
  local instance="$1"
  local conf_file="${BASE_DIR}/config_${instance}.json"
  local hop_file="${BASE_DIR}/hopping_${instance}.txt"
  local default_port=""

  [[ -f "$conf_file" ]] && default_port=$(jq -r '.inbounds[0].listen_port // empty' "$conf_file" 2>/dev/null)
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

  # 只要端口或配置重写，就干净清洗掉专属于该实例的历史防火墙跳跃链条
  clear_old_iptables "$instance"

  echo "---------------------------------------------"
  echo -e "实例端口群流控模式："
  echo -e " 1) 单端口独立模式"
  echo -e " 2) 端口跳跃分流模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择模式 [1-2] (直接回车保持默认跳跃): " jumpInput
  jumpInput=${jumpInput:-2}

  if [[ $jumpInput == 2 ]]; then
    while true; do
      read -rp "设置外部跳跃起始端口: " firstport
      read -rp "设置外部跳跃末尾端口: " endport
      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then
        echo "$firstport-$endport" > "$hop_file"
        break
      else error "无效的跳跃范围！"; fi
    done
  fi
  export EVAL_PORT="$port"
}

write_and_show_config() {
  local instance="$1"
  local conf_file="${BASE_DIR}/config_${instance}.json"
  local hy_dir="${HY2_DIR_BASE}/${instance}"
  local HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  local is_insecure="0"
  if [[ "$EVAL_DOMAIN" == "www.bing.com" ]]; then is_insecure="1"; fi

  local log_file="/var/log/sing-box-hy2_${instance}.log"

  cat << EOF > "$conf_file"
{
  "log": {
    "level": "info",
    "output": "$log_file",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in-${instance}",
      "listen": "::",
      "listen_port": $EVAL_PORT,
      "users": [ { "password": "$auth_pwd" } ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "server_name": "$EVAL_DOMAIN",
        "certificate_path": "$EVAL_CERT_PATH",
        "key_path": "$EVAL_KEY_PATH"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF

  chmod 640 "$conf_file"
  chown -R ${RUN_USER}:${RUN_USER} "$BASE_DIR"

  # 应用该实例专属防火墙跳跃
  apply_new_iptables "$instance" "$EVAL_PORT"
  
  # 创建多实例隔离客户端分享映射
  mkdir -p "$hy_dir"
  local final_port="$EVAL_PORT"
  if [[ -f "${BASE_DIR}/hopping_${instance}.txt" ]]; then
    final_port=$(cat "${BASE_DIR}/hopping_${instance}.txt")
  fi

  cat << EOF > "$hy_dir/url.txt"
矩阵独立子实例分享: [ ${instance} ]
外网出口地址: $vps_ip
V2rayN 链接:
hysteria2://$auth_pwd@$last_ip:$EVAL_PORT?sni=$EVAL_DOMAIN&insecure=${is_insecure}#$HOSTNAME-hy2-${instance}

Surge 配置:
$HOSTNAME-hy2-${instance} = hysteria2, $last_ip, $EVAL_PORT, password=$auth_pwd, skip-cert-verify=true, sni=$EVAL_DOMAIN
EOF

  register_instance "$instance"

  # 在 OpenRC 环境中创建专属实例软链接服务
  local svc_link="/etc/init.d/sing-box-hy2.${instance}"
  if [[ ! -L "$svc_link" && ! -f "$svc_link" ]]; then
    ln -sf "$OPENRC_SERVICE_PATH" "$svc_link"
    rc-update add "sing-box-hy2.${instance}" default >/dev/null 2>&1 || true
  fi

  rc-service "sing-box-hy2.${instance}" restart
  if rc-service "sing-box-hy2.${instance}" status | grep -q "started"; then
    info "sing-box Hysteria 2 子实例 [ ${instance} ] 配置下发并运行成功！"
  else
    error "实例服务下发完成，但拉起响应失败。请通过菜单选项 [8] 排查崩溃日志。"
  fi
  showconf
}

# =========================================================
# 7. 安装、更新与卸载控制流
# =========================================================
install_hy2() {
  info "开始在 Alpine 下部署多实例矩阵分流版 sing-box Hysteria 2 ..."
  check_environment
  
  write_openrc_template

  if [[ ! -f "$BINARY_PATH" ]]; then
    if ! download_core; then return 1; fi
  fi

  local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  if [[ -f "$conf_file" ]]; then
    warn "检测到当前聚焦的实例名 [ ${CURRENT_INSTANCE} ] 已经存在配置。"
    read -rp "是否彻底抹除、重新下发覆盖此实例配置？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
  fi

  inst_cert "$CURRENT_INSTANCE" || return 1
  inst_port "$CURRENT_INSTANCE"
  
  read -rp "设置 Hysteria 2 验证密码 (回车自动分配随机高强密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config "$CURRENT_INSTANCE"
}

update_hy2() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未检测到核心，无法执行覆盖升级。"
    return 1
  fi
  info "正在执行全局主内核引擎原地覆盖升级..."
  if download_core; then
    ok "全局共享主内核升级完毕，请手动重启各活跃实例使新核心生效。"
  else
    error "核心升级遭遇未预期中断。"
  fi
}

unsthy2() {
  warn "⚠️ 警告：该操作将直接抹除当前管理的实例 [ ${CURRENT_INSTANCE} ] 所有资源与配置。"
  read -rp "确定完全销毁并卸载此实例吗？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return
  
  rc-service "sing-box-hy2.${CURRENT_INSTANCE}" stop || true
  rc-update del "sing-box-hy2.${CURRENT_INSTANCE}" default >/dev/null 2>&1 || true
  rm -f "/etc/init.d/sing-box-hy2.${CURRENT_INSTANCE}"

  clear_old_iptables "$CURRENT_INSTANCE"
  if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
  if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi

  rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  rm -f "${BASE_DIR}/certs/cert_${CURRENT_INSTANCE}.pem" "${BASE_DIR}/certs/key_${CURRENT_INSTANCE}.pem"
  rm -rf "${HY2_DIR_BASE}/${CURRENT_INSTANCE}" "/var/log/sing-box-hy2_${CURRENT_INSTANCE}.log"

  unregister_instance "$CURRENT_INSTANCE"
  ok "矩阵实例 [ ${CURRENT_INSTANCE} ] 彻底安全移除。"

  # 矩阵自我净化：若全部实例都没了，清除主模板与用户
  sync_registry
  if [ ! -s "$REGISTRY_FILE" ]; then
    info "检测到矩阵内已无任何活跃节点，深度自动卸载全系统共享组件..."
    rm -f "$OPENRC_SERVICE_PATH" "$BINARY_PATH"
    rm -rf "$BASE_DIR" "$HY2_DIR_BASE"
    ok "全系统宿主机残留已深度彻底清洗清除。"
    CURRENT_INSTANCE="hy2"
  fi
}

changeconf() {
  local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  if [[ ! -f "$conf_file" ]]; then
    error "当前子实例配置不存在，请先选择选项 1 安装下发！"
    return 1
  fi

  local old_pwd=$(jq -r '.inbounds[0].users[0].password // empty' "$conf_file")
  local old_cert=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$conf_file")
  local old_key=$(jq -r '.inbounds[0].tls.key_path // empty' "$conf_file")
  local old_sni=$(jq -r '.inbounds[0].tls.server_name // "www.bing.com"' "$conf_file")

  clear
  echo -e "${GREEN}====== 修改实例 [ ${CURRENT_INSTANCE} ] 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port "$CURRENT_INSTANCE"

  read -rp "设置 Hysteria 2 验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert "$CURRENT_INSTANCE" || return 1
  else
    export EVAL_CERT_PATH="$old_cert"
    export EVAL_KEY_PATH="$old_key"
    export EVAL_DOMAIN="$old_sni"
  fi

  write_and_show_config "$CURRENT_INSTANCE"
  info "配置与分流转发链条刷新修改成功！"
}

showconf() {
  local hy_dir="${HY2_DIR_BASE}/${CURRENT_INSTANCE}"
  if [[ ! -d "$hy_dir" ]]; then
    error "未发现当前焦点实例 [ ${CURRENT_INSTANCE} ] 的分享配置文件。"
    return
  fi
  echo -e "${GREEN}====== Hysteria 2 节点分享与配置信息 (实例: ${CURRENT_INSTANCE}) ======${RESET}"
  cat "$hy_dir/url.txt"
  echo
}

# =========================================================
# 8. 矩阵分流多实例切换中心
# =========================================================
menu_switch_matrix() {
  echo -e "\n${GREEN}==== [sing-box Hysteria 2 多开实例矩阵分流中心] ====${RESET}"
  echo -e "当前聚焦的操作目标实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
  echo "当前已激活的矩阵实例列表:"

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
      
      local port_num=$(jq -r '.inbounds[0].listen_port // empty' "$c_file" 2>/dev/null)
      local status_str="${RED}已休眠挂起${RESET}"
      if rc-service "sing-box-hy2.${name}" status 2>/dev/null | grep -q "started"; then
         status_str="${GREEN}分流中${RESET}"
      fi
      echo -e " [ ${CYAN}${count}${RESET} ] -> 实例空间: ${YELLOW}${name}${RESET} [核心端口: ${port_num} | 运行状态: ${status_str}]"
    done < "$REGISTRY_FILE"
  fi

  if [ "$count" -eq 0 ]; then echo " (当前矩阵内空空如也，请直接在下方输入新名字创建第一个多开实例)"; fi
  
  echo ""
  echo -e "👉 ${GREEN}输入已有实例前面的【数字编号】快速切换管理焦点${RESET}"
  echo -e "👉 ${GREEN}或者直接输入一个【全新的英文别名】来新建独立多开实例${RESET}"
  read -rp "请输入您的选择: " input_val
  [[ -z "$input_val" ]] && return

  if [[ "$input_val" =~ ^[0-9]+$ ]]; then
    if [ "$input_val" -gt 0 ] && [ "$input_val" -le "$count" ]; then
      CURRENT_INSTANCE="${instance_list[$input_val]}"
      ok "操作焦点成功切换为已有实例: ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    else warn "编号超出可用范围！"; fi
  else
    if [[ "$input_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      CURRENT_INSTANCE="$input_val"
      ok "已锁定全新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET} (请选择菜单 [1] 下发独立节点配置)"
    else warn "命名不规范，仅支持英文字母、数字、中/下划线！"; fi
  fi
}

# =========================================================
# 9. 面板主菜单
# =========================================================
menu() {
  while true; do
    clear
    local raw_status=$(get_hy2_status)
    local status=""
    if [[ "$raw_status" == "RUNNING" ]]; then
      status="${YELLOW}● 运行中${RESET}"
    else
      status="${RED}● 未运行${RESET}"
    fi

    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}    ◈ Sing-box Hysteria2 矩阵面板 ◈   ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}当前控制目标 :${RESET} ${YELLOW}${CURRENT_INSTANCE}${RESET}"
    echo -e "${GREEN}分流核心端口 :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}实例服务状态 :${RESET} ${status}"
    echo -e "${GREEN}矩阵共享引擎 :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 1. 安装/下发当前焦点实例配置${RESET}"
    echo -e "${GREEN} 2. 更新全局共享主内核二进制程序${RESET}"
    echo -e "${GREEN} 3. 销毁并卸载当前焦点实例${RESET}"
    echo -e "${GREEN} 4. 精细修改当前焦点实例配置${RESET}"
    echo -e "${GREEN} 5. 启动当前焦点实例${RESET}"
    echo -e "${GREEN} 6. 停止当前焦点实例${RESET}"
    echo -e "${GREEN} 7. 重启当前焦点实例${RESET}"
    echo -e "${GREEN} 8. 查看当前实例的独立运行日志${RESET}"
    echo -e "${GREEN} 9. 打印查看当前实例客户端分享节点${RESET}"
    echo -e "${GREEN}10. 管理/切换节点矩阵分流中心${RESET}  ${YELLOW}← 添加 / 切换新旧多开子实例${RESET}"
    echo -e "${GREEN} 0. 安全退出面板控制台面${RESET}"
    echo -e "${GREEN}=======================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_hy2; pause ;;
      2) update_hy2; pause ;;
      3) unsthy2; pause ;;
      4) changeconf; pause ;;
      5) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" start && info "子实例已成功启动！"; pause ;;
      6) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" stop && info "子实例已转入挂起停止状态！"; pause ;;
      7) rc-service "sing-box-hy2.${CURRENT_INSTANCE}" restart && info "子实例已成功平滑重启！"; pause ;;
      8) 
        local log_file="/var/log/sing-box-hy2_${CURRENT_INSTANCE}.log"
        if [[ -f "$log_file" ]]; then 
          tail -n 50 "$log_file"; 
        else 
          warn "未发现该子实例运行日志文件。"; 
        fi
        pause ;;
      9) showconf; pause ;;
      10) menu_switch_matrix; sleep 1.5 ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

if [[ ${EUID} -ne 0 ]]; then
  error "请切换至 root 用户运行此面板脚本。"
  exit 1
fi

menu "$@"
