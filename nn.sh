#!/usr/bin/env bash
#
# sing-box (AnyTLS) 多实例核心控制面板 (Alpine OpenRC 适配版)
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

export TEMPLATE_NAME="mo-anytls-sb"
export CONFIG_DIR="/etc/mo-anytls-sb"
export BASE_DIR="/etc/mo-anytls-sb"
export EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
export DATA_BASE_DIR="/var/lib/sing-box"
export SB_DIR_BASE="/root/proxynode/Anytls"
export REGISTRY_FILE="${BASE_DIR}/.instances.env"

CURRENT_INSTANCE="$(hostname -s 2>/dev/null || echo "anytls")"

REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
SINGBOX_USER="${SINGBOX_USER:-sing-box}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "sbservinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { echo; read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键重新返回控制面板...${RESET}")"; }

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

is_alpine() {
  [[ -f /etc/alpine-release ]]
}

systemctl() {
  if is_alpine; then
    local action="$1"
    local svc_name="$2"
    # 将服务名形如 mo-anytls-sb@instance 转换为 OpenRC 的服务名或调用脚本
    # 在 Alpine 中通常使用单独的 init.d 脚本或传递参数
    local instance_name="${svc_name#*@}"
    local rc_script="/etc/init.d/${TEMPLATE_NAME}-${instance_name}"
    
    case "$action" in
      is-active)
        if [[ -f "$rc_script" ]] && rc-service "${TEMPLATE_NAME}-${instance_name}" status 2>/dev/null | grep -q "started"; then
          return 0
        else
          return 1
        fi
        ;;
      start)
        if [[ -f "$rc_script" ]]; then
          rc-service "${TEMPLATE_NAME}-${instance_name}" start
        fi
        ;;
      stop)
        if [[ -f "$rc_script" ]]; then
          rc-service "${TEMPLATE_NAME}-${instance_name}" stop
        fi
        ;;
      restart)
        if [[ -f "$rc_script" ]]; then
          rc-service "${TEMPLATE_NAME}-${instance_name}" restart
        fi
        ;;
      enable)
        if [[ -f "$rc_script" ]]; then
          rc-update add "${TEMPLATE_NAME}-${instance_name}" default >/dev/null 2>&1 || true
        fi
        ;;
      disable)
        if [[ -f "$rc_script" ]]; then
          rc-update del "${TEMPLATE_NAME}-${instance_name}" default >/dev/null 2>&1 || true
        fi
        ;;
      daemon-reload)
        # OpenRC 不需要 daemon-reload，忽略
        return 0
        ;;
      *)
        return 0
        ;;
    es      case
  else
    if ! has_command systemctl; then
      warn "当前系统不支持 systemd，忽略守护进程操作: systemctl $*"
      return 0
    fi
    command systemctl "$@"
  fi
}

journalctl() {
  if is_alpine; then
    local log_file="/var/log/${TEMPLATE_NAME}-${CURRENT_INSTANCE}.log"
    if [[ -f "$log_file" ]]; then
      tail -n "$@" "$log_file"
    else
      echo "暂无运行日志文件: $log_file"
    fi
  else
    if has_command journalctl; then
      command journalctl "$@"
    else
      echo "当前系统不支持 journalctl"
    fi
  fi
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
    error "未检测到支持的包管理器，请手动安装 $_package_name"
    exit 65
  fi
  echo "正在安装缺失的依赖 '$_package_name' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    error "无法通过包管理器安装 '$_package_name'，请手动安装。"
    exit 65
  fi
}

check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  case "$(uname -m)" in
    'i386' | 'i686') ARCHITECTURE='386' ;;
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='armv7' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    's390x') ARCHITECTURE='s390x' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command openssl || install_software openssl
  has_command tar || install_software tar
  has_command socat || install_software socat
  has_command python3 || install_software python3
  if is_alpine; then
    has_command openrc || install_software openrc
    has_command shadow || install_software shadow
  fi
}

# =========================================================
# 2.5 权限修复与实例注册管理
# =========================================================
fix_external_cert_permission() {
  local cert=$1
  local key=$2
  
  if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
    error "致命拒绝: 检测到您的证书位于 /root/ 目录下！非 root 运行用户无权穿透读取。"
    info "权威推荐: 请将证书导出到公共目录（如 /etc/ssl/ ）再试。"
    return 1
  fi

  local cert_dir=$(dirname "$cert")
  chmod +x "$cert_dir" 2>/dev/null || true
  chmod 644 "$cert" "$key" 2>/dev/null || true
  
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:"$SINGBOX_USER":rx "$cert_dir" 2>/dev/null || true
    setfacl -m u:"$SINGBOX_USER":r "$cert" "$key" 2>/dev/null || true
  fi
  return 0
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
  for f in "${BASE_DIR}"/config_*.json; do
    [ -e "$f" ] || continue
    local name=$(basename "$f" | sed 's/^config_//;s/\.json$//')
    if [ -n "$name" ]; then echo "$name" >> "$temp_reg"; fi
  done
  mv -f "$temp_reg" "$REGISTRY_FILE"
}

write_systemd_template() {
  local instance="$1"
  if is_alpine; then
    local openrc_script="/etc/init.d/${TEMPLATE_NAME}-${instance}"
    local log_file="/var/log/${TEMPLATE_NAME}-${instance}.log"
    cat << EOF > "$openrc_script"
#!/sbin/openrc-run

name="${TEMPLATE_NAME}-${instance}"
description="sing-box AnyTLS OpenRC Service for instance ${instance}"
cfgfile="${BASE_DIR}/config_${instance}.json"
logfile="${log_file}"
command="$EXECUTABLE_INSTALL_PATH"
command_args="run -c ${BASE_DIR}/config_${instance}.json"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "\$cfgfile" ]; then
        eerror "Configuration file \$cfgfile missing!"
        return 1
    fi
    
    touch "\$logfile"
    chown $SINGBOX_USER:$SINGBOX_USER "\$logfile"
    chmod 644 "\$logfile"
    
    command_background="yes"
    pidfile="/run/\${RC_SVCNAME}.pid"
    
    output_log="\$logfile"
    error_log="\$logfile"
    
    local port
    port=\$(jq -r '.inbounds[0].listen_port // 0' "\$cfgfile" 2>/dev/null)
    if [ "\$port" -lt 1024 ] && [ "\$port" -ne 0 ]; then
        command_user="root:root"
    else
        command_user="$SINGBOX_USER:$SINGBOX_USER"
    fi
}
EOF
    chmod +x "$openrc_script"
  else
    local template_file="/etc/systemd/system/${TEMPLATE_NAME}@.service"
    cat << EOF > "$template_file"
[Unit]
Description=sing-box AnyTLS Service - Instance: %I
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH run --config ${BASE_DIR}/config_%I.json
WorkingDirectory=${DATA_BASE_DIR}/%I
User=$SINGBOX_USER
Group=$SINGBOX_USER
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null | head -n 1 || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
    else echo "未知版本"; fi
  else echo "未安装"; fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases/latest" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '.tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  if [[ -n "$_tag_name" ]]; then echo "${_tag_name##*v}"; else echo ""; fi
}

download_singbox() {
  local _version="$1"
  local _destination="$2"
  local _download_url="$REPO_URL/releases/download/v${_version}/sing-box-${_version}-linux-${ARCHITECTURE}.tar.gz"
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查网络。"
    return 11
  fi
  return 0
}

# =========================================================
# 3. 网络与状态辅助函数
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
  if ss -tunlp 2>/dev/null | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
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

get_sb_status() {
  if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    echo -e "${RED}● 未运行${RESET}"
  fi
}

get_current_port_display() {
  local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  if [[ -f "$conf_file" ]]; then
    local main_port=$(jq -r '.inbounds[0].listen_port' "$conf_file" 2>/dev/null || echo "")
    echo "${main_port:- -}"
  else echo "实例未初始化"; fi
}

# =========================================================
# 4. 证书与端口配置交互
# =========================================================
inst_cert() {
  local instance="$1"
  local cert_path="${BASE_DIR}/fullchain_${instance}.pem"
  local key_path="${BASE_DIR}/privkey_${instance}.pem"
  local conf_file="${BASE_DIR}/config_${instance}.json"

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    echo "---------------------------------------------"
    echo -e "${YELLOW}[提示] 检测到实例 [ ${instance} ] 已有历史证书文件。${RESET}"
    read -rp "是否要重新配置证书？[y/N] (直接回车保持不变): " cert_change_choice
    cert_change_choice=${cert_change_choice:-n}
    if [[ ! "$cert_change_choice" =~ ^[Yy]$ ]]; then
      info "保持原有证书配置不变。"
      local old_sni="www.bing.com"
      [[ -f "$conf_file" ]] && old_sni=$(jq -r '.inbounds[0].tls.server_name' "$conf_file" 2>/dev/null || echo "www.bing.com")
      export EVAL_CERT_PATH="$cert_path"
      export EVAL_KEY_PATH="$key_path"
      export EVAL_DOMAIN="${old_sni:-"www.bing.com"}"
      return 0
    fi
  fi

  echo "---------------------------------------------"
  echo -e "实例 [ ${instance} ] 证书配置选择："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme自动申请 (需放行 80 端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (回车默认自签): " certInput
  certInput=${certInput:-1}

  if [[ $certInput == 2 ]]; then
    local vps_ip=$(get_public_ip)
    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && error "未输入域名，操作取消！" && return 1
    
    local acme_cmd="/root/.acme.sh/acme.sh"
    [[ ! -f "$acme_cmd" ]] && curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
    
    "$acme_cmd" --set-default-ca --server letsencrypt
    local reload_cmd="systemctl restart ${TEMPLATE_NAME}@${instance}"
    
    if [[ "$vps_ip" =~ ":" ]]; then
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    else
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi
    
    if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc --reloadcmd "$reload_cmd"; then
      sb_domain=$domain
      info "Acme 独立实例证书部署成功！"
    else
      error "Acme 申请失败，降级回自签模式。"
      certInput=1
    fi
  elif [[ $certInput == 3 ]]; then
    while true; do
      local user_cert user_key
      read -rp "请输入公钥文件绝对路径: " user_cert
      read -rp "请输入密钥文件绝对路径: " user_key
      read -rp "请输入对应域名: " sb_domain
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
    rm -f "$cert_path" "$key_path"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    sb_domain="www.bing.com"
  fi

  chown -h "$SINGBOX_USER":"$SINGBOX_USER" "$cert_path" "$key_path" 2>/dev/null || true
  export EVAL_CERT_PATH="$cert_path"
  export EVAL_KEY_PATH="$key_path"
  export EVAL_DOMAIN="$sb_domain"
}

inst_port() {
  local instance="$1"
  local conf_file="${BASE_DIR}/config_${instance}.json"
  local default_port=""
  [[ -f "$conf_file" ]] && default_port=$(jq -r '.inbounds[0].listen_port' "$conf_file" 2>/dev/null || echo "")

  local prompt_msg="设置该实例监听端口 (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置该实例监听端口 [当前: ${default_port}, 回车不修改]: "

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
}

print_node_summary() {
  local instance="$1"
  local conf_file="${BASE_DIR}/config_${instance}.json"
  if [ ! -f "$conf_file" ]; then return; fi

  local hostname=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)
  local main_port=$(jq -r '.inbounds[0].listen_port' "$conf_file" 2>/dev/null || echo "")
  local auth_pwd=$(jq -r '.inbounds[0].users[0].password' "$conf_file" 2>/dev/null || echo "")
  local sb_domain=$(jq -r '.inbounds[0].tls.server_name' "$conf_file" 2>/dev/null || echo "www.bing.com")

  local is_insecure="0" skip_cert="false"
  if [[ "$sb_domain" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

  local url_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && url_ip="[$vps_ip]"

  echo -e "\n${GREEN}== sing-box (AnyTLS) 实例${RESET}${YELLOW} [ ${instance} ]${RESET} ${GREEN}配置详情 ==${RESET}"
  echo -e "${GREEN}外网绑定 IP  :${RESET} $vps_ip"
  echo -e "${GREEN}监听端口     :${RESET} $main_port"
  echo -e "${GREEN}验证密码     :${RESET} $auth_pwd"
  echo -e "${GREEN}伪装 SNI 域  :${RESET} $sb_domain"
  echo -e "${GREEN}配置文件路径 :${RESET} $conf_file"
  echo -e "${GREEN}--------------------------------------------${RESET}"
  echo -e "${GREEN}👉 V2rayN 订阅链接:${RESET}"
  echo -e "${YELLOW}anytls://$auth_pwd@$url_ip:$main_port?security=tls&sni=$sb_domain&insecure=${is_insecure}&allowInsecure=${is_insecure}&type=tcp#$hostname-anytls-${instance}${RESET}"
  echo ""
  echo -e "${GREEN}👉 Surge 专属配置格式:${RESET}"
  echo -e "${YELLOW}$hostname-${instance}-AnyTLS = anytls, $url_ip, $main_port, password=$auth_pwd, sni=$sb_domain, tfo=true, skip-cert-verify=${skip_cert}, reuse=false${RESET}"
  echo ""
}

write_and_show_config() {
  local instance="$1"
  local conf_file="${BASE_DIR}/config_${instance}.json"
  local sb_dir="${SB_DIR_BASE}/${instance}"
  local vps_ip=$(get_public_ip)
  local url_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && url_ip="[$vps_ip]"

  cat << EOF > "$conf_file"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "name": "user1",
          "password": "$auth_pwd"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$EVAL_DOMAIN",
        "key_path": "$EVAL_KEY_PATH",
        "certificate_path": "$EVAL_CERT_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  mkdir -p "$sb_dir"
  local inst_data_dir="${DATA_BASE_DIR}/${instance}"
  install -m 0750 -o "$SINGBOX_USER" -g "$SINGBOX_USER" -d "$inst_data_dir"
  
  chown "$SINGBOX_USER":"$SINGBOX_USER" "$conf_file" 2>/dev/null || true
  chown -h "$SINGBOX_USER":"$SINGBOX_USER" "$EVAL_CERT_PATH" "$EVAL_KEY_PATH" 2>/dev/null || true
  register_instance "$instance"

  write_systemd_template "$instance"
  systemctl daemon-reload
  systemctl enable "${TEMPLATE_NAME}@${instance}" >/dev/null 2>&1 || true
  systemctl restart "${TEMPLATE_NAME}@${instance}" >/dev/null 2>&1 || true

  if systemctl is-active --quiet "${TEMPLATE_NAME}@${instance}" 2>/dev/null; then
    print_node_summary "$instance"
  else
    error "实例服务下发完成，但启动响应失败。请通过菜单 [8] 查看日志。"
  fi
}

instsingbox() {
  local mode="${1:-new}"
  check_environment
  [ -d "$BASE_DIR" ] || install -m 0755 -d "$BASE_DIR"

  if [[ ! -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    info "核心组件缺失，正在拉取最新 sing-box 引擎..."
    local latest_version=$(get_latest_version)
    [[ -z "$latest_version" ]] && error "无法获取云端版本号！" && return 1
    local _tmparchive=$(mktemp)
    download_singbox "$latest_version" "$_tmparchive" || return 1
    local _tmpdir=$(mktemp -d)
    tar -xzf "$_tmparchive" -C "$_tmpdir"
    install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"
    rm -rf "$_tmparchive" "$_tmpdir"
  fi

  if ! is_user_exists "$SINGBOX_USER"; then
    if is_alpine; then
      addgroup -S "$SINGBOX_USER" 2>/dev/null || true
      adduser -S -D -H -G "$SINGBOX_USER" -s /sbin/nologin "$SINGBOX_USER" 2>/dev/null || true
    else
      useradd -r -d "$DATA_BASE_DIR" -m "$SINGBOX_USER" >/dev/null 2>&1 || true
    fi
  fi
  write_systemd_template "$CURRENT_INSTANCE"

  local conf_file="${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  if [[ "$mode" == "new" && -f "$conf_file" ]]; then
    echo -e "${YELLOW}[WARN]检测到实例 [ ${CURRENT_INSTANCE} ] 已经存在配置。${RESET}"
    read -r -p "$(echo -e "${GREEN}是否强行覆盖并重置该实例？[y/N]: ${RESET}")" confirm || true
    [[ "$confirm" =~ ^[Yy]$ ]] || return
  fi

  if [[ "$mode" == "edit" ]]; then
    echo -e "\n${GREEN}==== [正在修改实例参数: ${CURRENT_INSTANCE}] ====${RESET}"
    local old_pwd=$(jq -r '.inbounds[0].users[0].password' "$conf_file" 2>/dev/null || true)
  fi

  inst_cert "$CURRENT_INSTANCE" || return 1
  inst_port "$CURRENT_INSTANCE"

  if [[ "$mode" == "edit" ]]; then
    read -rp "设置新认证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
    auth_pwd=${auth_pwd:-$old_pwd}
  else
    read -rp "设置 AnyTLS 验证密码 (回车分配高强度随机密钥): " auth_pwd
    auth_pwd=${auth_pwd:-$(generate_random_password)}
  fi

  write_and_show_config "$CURRENT_INSTANCE"
}

unstsingbox() {
  echo -e "${YELLOW}[WARN]该操作将彻底销毁清理当前聚焦的 [ ${CURRENT_INSTANCE} ] 实例。${RESET}"
  read -r -p "$(echo -e "${RED}确定完全卸载移除此实例？[y/N]: ${RESET}")" confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return

  systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
  systemctl disable "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" >/dev/null 2>&1 || true
  if is_alpine; then
    rm -f "/etc/init.d/${TEMPLATE_NAME}-${CURRENT_INSTANCE}"
  fi

  rm -f "${BASE_DIR}/config_${CURRENT_INSTANCE}.json"
  rm -f "${BASE_DIR}/fullchain_${CURRENT_INSTANCE}.pem" "${BASE_DIR}/privkey_${CURRENT_INSTANCE}.pem"
  rm -rf "${DATA_BASE_DIR}/${CURRENT_INSTANCE}" "/root/proxynode/Anytls/${CURRENT_INSTANCE}"

  unregister_instance "$CURRENT_INSTANCE"
  info "实例 [ ${CURRENT_INSTANCE} ] 已彻底移除。"

  sync_registry
  if [ ! -s "$REGISTRY_FILE" ]; then
    info "检测到矩阵内已无活跃节点，自动清理全局共享组件..."
    if is_alpine; then
      rm -f /etc/init.d/${TEMPLATE_NAME}-*
    else
      rm -f /etc/systemd/system/${TEMPLATE_NAME}@.service /etc/systemd/system/${TEMPLATE_NAME}.service
    fi
    rm -f "$EXECUTABLE_INSTALL_PATH"
    rm -rf "$BASE_DIR" "$DATA_BASE_DIR"
    userdel "$SINGBOX_USER" >/dev/null 2>&1 || true
    systemctl daemon-reload
    CURRENT_INSTANCE="anytls"
  fi
}

menu_switch_matrix() {
  echo -e "\n${GREEN}==== [sing-box 多开实例中心] ====${RESET}"
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
      
      local port_num=$(jq -r '.inbounds[0].listen_port' "$c_file" 2>/dev/null || echo "")
      local status_str="${RED}已停止${RESET}"
      if systemctl is-active --quiet "${TEMPLATE_NAME}@${name}"; then status_str="${GREEN}运行中${RESET}"; fi
      echo -e " ${CYAN}[ ${count} ] ->${GREEN} 实例名: ${YELLOW}${name}${RESET} ${GREEN}[绑定端口: ${port_num} | 运行状态: ${status_str}${GREEN}]${RESET}"
    done < "$REGISTRY_FILE"
  fi

  [ "$count" -eq 0 ] && echo -e " ${YELLOW}(当前矩阵内暂无实例，可在下方输入新名字直接创建)${RESET}"
  
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
    else error "编号超出可用范围！"; fi
  else
    if [[ "$input_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      CURRENT_INSTANCE="$input_val"
      echo -e "${GREEN}成功锁定并创建新焦点: ${YELLOW}${CURRENT_INSTANCE}${RESET}${GREEN} (请在主菜单选择 [1] 下发部署服务)${RESET}"
    else error "命名不规范，仅限使用英文字母、数字、中划线和下划线！"; fi
  fi
}

update_singbox() {
  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local latest_version=$(get_latest_version)
  [[ -z "$latest_version" ]] && error "无法获取云端版本号！" && return 1

  info "当前版本: ${YELLOW}${current_version}${RESET} ${GREEN}| 最新版本:${RESET} ${YELLOW}${latest_version}${RESET}"
  [[ "$current_version" == "$latest_version" ]] && info "已经是最新版本，无需更新。" && return 0

  local _tmparchive=$(mktemp)
  download_singbox "$latest_version" "$_tmparchive" || return 1
  local _tmpdir=$(mktemp -d)
  tar -xzf "$_tmparchive" -C "$_tmpdir"
  install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"
  rm -rf "$_tmparchive" "$_tmpdir"
  info "核心更新完毕！请视情况手动重启运行中的实例。"
}

# =========================================================
# 5. 拓展组件：自适应配置当前实例的 Socks5 出口
# =========================================================
configure_custom_socks5_outbound() {
    local instance_config="${CONFIG_DIR}/config_${CURRENT_INSTANCE}.json"
    if [[ ! -f "$instance_config" ]]; then 
        echo -e "${RED}[ERROR]未安装，无法配置出口模式。${RESET}" >&2
        return
    fi

    local mode current_protocol tmp_file
    current_protocol=$(jq -r '.outbounds[0].type // "direct"' "$instance_config" 2>/dev/null || echo "direct")

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
            jq '.outbounds = [{"type":"direct","tag":"direct"}]' "$instance_config" > "$tmp_file"
            if ! jq empty "$tmp_file" >/dev/null 2>&1; then
                rm -f "$tmp_file"
                echo -e "${RED}[ERROR]生成的直连配置无效。${RESET}" >&2
                return 1
            fi
            cp "$instance_config" "${instance_config}.bak.$(date +%s)"
            mv "$tmp_file" "$instance_config"
            chmod 644 "$instance_config" 2>/dev/null || true
            
            systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
            sleep 0.5
            if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
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
    es

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
                "type": "socks",
                "tag": "custom-socks5-out",
                "server": $host,
                "server_port": $port,
                "username": $user,
                "password": $pass
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
                "type": "socks",
                "tag": "custom-socks5-out",
                "server": $host,
                "server_port": $port
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

    systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"
    sleep 0.5
    if systemctl is-active --quiet "${TEMPLATE_NAME}@${CURRENT_INSTANCE}"; then
        echo -e "${GREEN}[OK]已成功切换为 Socks5 出口！${RESET}"
    else
        echo -e "${RED}[ERROR]重启服务失败，当前配置可能与系统环境不兼容。${RESET}" >&2
        return 1
    fi
}

menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_sb_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}   ◈   sing-box AnyTLS多实例管理面板   ◈    ${RESET}"
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
    echo -e "${GREEN}10. Socks5出口${RESET}     ${YELLOW}← 链式分流代理${RESET}"
    echo -e "${GREEN}11. 管理实例${RESET}      ${YELLOW}← 添加/切换节点${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"

    local choice=""
    read -r -p $'\033[32m选择操作序号: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) instsingbox "new"; pause ;;
      2) update_singbox; pause ;;
      3) unstsingbox; pause ;;
      4) instsingbox "edit"; pause ;;
      5) systemctl start "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && info "启动成功" ; pause ;;
      6) systemctl stop "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && info "停止成功" ; pause ;;
      7) systemctl restart "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" && info "重启完毕" ; pause ;;
      8) 
        echo -e "${YELLOW}正在调取该实例实时日志 (按 Ctrl+C 退出):${RESET}\n"
        journalctl -u "${TEMPLATE_NAME}@${CURRENT_INSTANCE}" -n 50 -f || true
        ;;
      9) print_node_summary "$CURRENT_INSTANCE"; pause ;;
      10) configure_custom_socks5_outbound; pause ;;
      11) menu_switch_matrix ;;
      0) clear; exit 0 ;;
      *) warn "输入未知操作序号！"; sleep 0.5 ;;
    esac
  done
}

menu "$@"
