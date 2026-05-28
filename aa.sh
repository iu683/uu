#!/usr/bin/env bash
#
# Tuic 管理面板 (iptables 端口跳跃版)
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly TUIC_CONFIG="/etc/tuic/server.json"
readonly TUIC_BINARY="/usr/local/bin/tuic-server"
readonly TUIC_DIR="/root/tuic"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/tuic-server"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/tuic"
REPO_URL="https://github.com/EAimTY/tuic"
API_BASE_URL="https://api.github.com/repos/EAimTY/tuic"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 官方原生底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "tuicinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

systemctl() {
  if ! has_command systemctl; then
    warn "忽略 systemd 命令: systemctl $@"
    return
  fi
  command systemctl "$@"
}

install_content() {
  local _install_flags="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"
  local _tmpfile="$(mktemp)"

  echo -ne "安装 $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "已存在"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "完成"
  fi
  rm -f "$_tmpfile"
}

remove_file() {
  local _target="$1"
  echo -ne "移除 $_target ... "
  if rm -f "$_target"; then
    echo -e "完成"
  fi
}

detect_package_manager() {
  [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]] && return 0
  has_command apt && PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install' && return 0
  has_command dnf && PACKAGE_MANAGEMENT_INSTALL='dnf -y install' && return 0
  has_command yum && PACKAGE_MANAGEMENT_INSTALL='yum -y install' && return 0
  return 1
}

install_software() {
  local _package_name="$1"
  if ! detect_package_manager; then
    error "未检测到支持的包管理器，请手动安装 $_package_name"
    exit 65
  fi
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name" >/dev/null 2>&1; then
    return 0
  else
    return 1
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
    'x86_64' | 'amd64') ARCHITECTURE='x86_64' ;;
    'aarch64' | 'arm64') ARCHITECTURE='aarch64' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command openssl || install_software openssl
  has_command iptables || install_software iptables
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" -v 2>/dev/null || "$EXECUTABLE_INSTALL_PATH" --version 2>/dev/null || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases" -o "$_tmpfile"; then
    echo ""
    rm -f "$_tmpfile"
    return
  fi
  # 筛选最新非 pre-release 的 tuic-server 版本
  local _latest_version=$(jq -r '[.[] | select(.prerelease==false and (.assets[].name | contains("tuic-server")))] | first | .tag_name' "$_tmpfile")
  _latest_version=${_latest_version#tuic-server-}
  echo "$_latest_version"
  rm -f "$_tmpfile"
}

download_tuic() {
  local _version="$1"
  local _destination="$2"
  local _download_url="$REPO_URL/releases/download/tuic-server-$_version/tuic-server-$_version-$ARCHITECTURE-$OPERATING_SYSTEM"
  info "正在下载官方 Tuic 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_tuic_server_service() {
  cat << EOF
[Unit]
Description=Tuic Server Service
After=network.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH --config $TUIC_CONFIG
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. iptables 规则持久化与控制模块 (核心改动)
# =========================================================
# 确保防火墙规则在重启后依然生效
ensure_iptables_persistent() {
  if has_command dpkg; then
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
      info "正在安装 iptables-persistent 以确保重启后规则不丢失..."
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
      install_software iptables-persistent || log "安装持久化工具失败，规则可能在重启后失效"
    fi
  elif has_command rpm; then
    if ! rpm -q iptables-services >/dev/null 2>&1; then
      info "正在安装 iptables-services 以确保重启后规则不丢失..."
      install_software iptables-services && systemctl enable iptables ip6tables && systemctl start iptables ip6tables || true
    fi
  fi
}

save_iptables_rules() {
  ensure_iptables_persistent
  if has_command iptables-save; then
    if [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    elif [[ -f /etc/sysconfig/iptables ]]; then
      iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
      ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
    fi
  fi
}

# 彻底清除之前的旧转发规则，防止累加污染防火墙
clear_old_iptables() {
  if [[ -f "${CONFIG_DIR}/hopping.txt" && -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local old_hop=$(cat "${CONFIG_DIR}/hopping.txt")
    local old_port=$(cat "${CONFIG_DIR}/main_port.txt")
    local old_start=${old_hop%-*}
    local old_end=${old_hop#*-}

    if [[ -n "$old_start" && -n "$old_end" && -n "$old_port" ]]; then
      iptables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      ip6tables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
    fi
  fi
}

# 建立新的端口跳跃规则
apply_new_iptables() {
  clear_old_iptables
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    
    info "正在应用 iptables 转发规则: UDP $start_p-$end_p => 主端口 $port"
    iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port"
    ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    
    # 写入缓存备忘，供下次清理或显示使用
    echo "$port" > "${CONFIG_DIR}/main_port.txt"
    save_iptables_rules
  fi
}

# =========================================================
# 4. 面板辅助网络与配置扩展函数
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
    error "无法获取公网 IP 地址。" && return 1
}

check_port() {
  local port="$1"
  if ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
    return 1
  fi
  return 0
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_random_port() {
  local rand_port
  while true; do
    rand_port=$(shuf -i 2000-65535 -n 1)
    if check_port "$rand_port"; then
      echo "$rand_port" && return 0
    fi
  done
}

get_tuic_status() {
  if systemctl is-active --quiet tuic-server 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    echo -e "${RED}● 未运行${RESET}"
  fi
}

get_current_port_display() {
  if [[ -f "$TUIC_CONFIG" ]]; then
    local main_port jump_range="无"
    main_port=$(jq -r '.port' "$TUIC_CONFIG" 2>/dev/null || echo "")
    [[ -f "${CONFIG_DIR}/hopping.txt" ]] && jump_range=$(cat "${CONFIG_DIR}/hopping.txt")
    
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [iptables 转发: ${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "-"; fi
}

# =========================================================
# 5. 面板交互与配置生成逻辑
# =========================================================
inst_cert() {
  echo "---------------------------------------------"
  echo -e "Tuic 协议证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme 脚本自动申请"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  if [[ $certInput == 2 ]]; then
    cert_path="/root/cert.crt"
    key_path="/root/private.key"
    chmod a+x /root

    if [[ -f /root/cert.crt && -f /root/private.key && -s /root/cert.crt && -s /root/private.key && -f /root/ca.log ]]; then
      tuic_domain=$(cat /root/ca.log)
      info "检测到原有域名 [${tuic_domain}] 的证书，正在复用..."
    else
      local vps_ip=$(get_public_ip)
      read -rp "请输入需要申请证书的域名: " domain
      [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
      
      info "正在借助 Acme 脚本自动向 Let's Encrypt 申请证书..."
      curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
      local acme_cmd="/root/.acme.sh/acme.sh"
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      if [[ "$vps_ip" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      "$acme_cmd" --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
      
      if [[ -f /root/cert.crt && -f /root/private.key ]]; then
        echo "$domain" > /root/ca.log
        tuic_domain=$domain
      else
        error "Acme 证书申请失败，自动切换回自签模式。"
        certInput=1
      fi
    fi
  elif [[ $certInput == 3 ]]; then
    read -rp "请输入公钥文件 crt 的路径: " cert_path
    read -rp "请输入密钥文件 key 的路径: " key_path
    read -rp "请输入证书对应的域名: " tuic_domain
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 Tuic 的节点证书"
    mkdir -p /etc/tuic
    cert_path="/etc/tuic/cert.crt"
    key_path="/etc/tuic/private.key"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    chmod 644 "$cert_path" "$key_path"
    tuic_domain="www.bing.com"
  fi
}

inst_port() {
  local default_port=""
  if [[ -f "$TUIC_CONFIG" ]]; then
    default_port=$(jq -r '.port' "$TUIC_CONFIG" 2>/dev/null || echo "")
  fi

  local prompt_msg="设置 Tuic 服务端监听主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 Tuic 服务端监听主端口 [当前: ${default_port}, 回车不修改]: "

  while true; do
    read -rp "$prompt_msg" port
    if [[ -z "$port" ]]; then
      if [[ -n "$default_port" ]]; then port="$default_port" && break
      else
        port=$(get_random_port)
        info "已为您随机分配未被占用端口: $port" && break
      fi
    elif is_valid_port "$port"; then
      if [[ "$port" != "$default_port" ]] && ! check_port "$port"; then
        error "端口 ${port} 已被其它程序占用，请更换。" && continue
      fi
      break
    else error "请输入有效的端口数字 (1-65535)"; fi
  done

  echo "---------------------------------------------"
  echo -e "Tuic 端口群使用模式 (通过 iptables 实现)："
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
  jumpInput=${jumpInput:-2}

  # 先尝试清除之前旧的规则
  clear_old_iptables

  if [[ $jumpInput == 2 ]]; then
    while true; do
      read -rp "设置外部跳跃起始端口 (建议10000-65535): " firstport
      read -rp "设置外部跳跃末尾端口 (必须大于起始端口): " endport
      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then break
      else error "输入无效，起始端口必须小于末尾端口，请重新输入。"; fi
    done
    mkdir -p "$CONFIG_DIR"
    echo "$firstport-$endport" > "${CONFIG_DIR}/hopping.txt"
  else
    rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt"
    info "将继续使用单端口模式"
  fi
}

write_and_show_config() {
  local HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  # 🌟 核心：Tuic 配置文件内部只绑定独立的主端口，纯净无杂质
  cat << EOF > /etc/tuic/server.json
{
  "port": $port,
  "certificate": "$cert_path",
  "private_key": "$key_path",
  "users": {
    "$auth_uuid": "$auth_pwd"
  },
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_mode": "native",
  "log_level": "info"
}
EOF

  # 🌟 应用外部 iptables 转发机制
  apply_new_iptables

  mkdir -p "$TUIC_DIR"
  
  # 拼装适用于客户端的多端口格式 (如：mport=10000-20000)
  local hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  # 生成标准的 Tuic v5 订阅与节点数据
  cat << EOF > "$TUIC_DIR/url.txt"
NekoBox / V2rayN (Tuic v5 分享链接):
tuic://$auth_uuid:$auth_pwd@$last_ip:$port?alpn=h3&congestion_control=bbr&udp_relay_mode=native&sni=$tuic_domain&allow_insecure=1${hopping_param}#$HOSTNAME-tuic

Clash Meta / Mihomo 格式备忘:
- name: $HOSTNAME-tuic
  type: tuic
  server: $vps_ip
  port: $port
  uuid: $auth_uuid
  password: $auth_pwd
  alpn: [h3]
  sni: $tuic_domain
  skip-cert-verify: true
EOF

  systemctl daemon-reload
  systemctl enable tuic-server >/dev/null 2>&1 || true
  systemctl restart tuic-server >/dev/null 2>&1 || true

  if systemctl is-active --quiet tuic-server 2>/dev/null; then
    info "Tuic 服务配置并启动成功！"
  else
    error "Tuic 服务启动失败，请运行 'systemctl status tuic-server' 查看日志。"
  fi
  showconf
}

# =========================================================
# 6. 主流程控制模块与更新功能
# =========================================================
insttuic() {
  check_environment
  
  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  if [[ -z "$latest_version" ]]; then
    error "无法获取最新版本号，请检查网络设置。"
    return 1
  fi
  
  local _tmpfile=$(mktemp)
  if ! download_tuic "$latest_version" "$_tmpfile"; then
    rm -f "$_tmpfile" && return 1
  fi

  echo -ne "正在安装二进制可执行文件 ... "
  if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -f "$_tmpfile" && error "安装失败" && return 1
  fi
  rm -f "$_tmpfile"

  mkdir -p "$CONFIG_DIR"
  install_content -Dm644 "$(tpl_tuic_server_service)" "$SYSTEMD_SERVICES_DIR/tuic-server.service" "1"

  inst_cert || return 1
  inst_port
  
  read -rp "设置 Tuic 验证 UUID (回车自动分配随机 UUID): " auth_uuid
  auth_uuid=${auth_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "12345678-1234-1234-1234-123456781234")}
  
  read -rp "设置 Tuic 验证密码 (回车自动分配随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_tuic() {
  if [[ ! -f "$TUIC_BINARY" ]]; then
    error "当前系统未安装 Tuic，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local latest_version=$(get_latest_version)

  if [[ -z "$latest_version" ]]; then
    error "无法连接到 GitHub API 获取最新版本，请稍后再试。"
    return 1
  fi

  info "当前安装版本: ${YELLOW}${current_version}${RESET}"
  info "官方最新版本: ${GREEN}${latest_version}${RESET}"

  if [[ "$current_version" == "$latest_version" ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "检测到新版本，即将开始平滑更新 (原有防火墙转发及配置不会受损)..."
  
  local _tmpfile=$(mktemp)
  if ! download_tuic "$latest_version" "$_tmpfile"; then
    rm -f "$_tmpfile" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -f "$_tmpfile" && error "覆盖核心失败" && return 1
  fi
  rm -f "$_tmpfile"

  info "正在重启 Tuic 服务以应用更新..."
  systemctl restart tuic-server >/dev/null 2>&1 || true

  if systemctl is-active --quiet tuic-server 2>/dev/null; then
    info "Tuic 已成功平滑更新至至 ${GREEN}${latest_version}${RESET}！"
  else
    error "核心更新成功，但服务重启失败，请运行 'systemctl status tuic-server' 检查错误。"
  fi
}

unsttuic() {
  warn "即将从当前系统中彻底卸载 Tuic 并清理防火墙转发规则"

  # 彻底清除可能残留的端口跳跃 iptables 规则
  clear_old_iptables
  save_iptables_rules

  systemctl stop tuic-server >/dev/null 2>&1 || true
  systemctl disable tuic-server >/dev/null 2>&1 || true
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  remove_file "$SYSTEMD_SERVICES_DIR/tuic-server.service"
  
  systemctl daemon-reload
  rm -rf /etc/tuic "$TUIC_DIR"
  
  info "Tuic 已彻底从您的系统中移除，防火墙规则已恢复！"
}

changeconf() {
  if [[ ! -f "$TUIC_CONFIG" ]]; then
    error "配置文件不存在，请先安装 Tuic"
    return 1
  fi

  local old_uuid=$(jq -r '.users | keys[0]' "$TUIC_CONFIG" 2>/dev/null || echo "")
  local old_pwd=$(jq -r ".users.\"$old_uuid\"" "$TUIC_CONFIG" 2>/dev/null || echo "")
  local old_cert=$(jq -r '.certificate' "$TUIC_CONFIG" 2>/dev/null || echo "")
  local old_key=$(jq -r '.private_key' "$TUIC_CONFIG" 2>/dev/null || echo "")
  local old_sni="www.bing.com"
  [[ -f "$TUIC_DIR/url.txt" ]] && old_sni=$(grep -E '^\s*sni:' "$TUIC_DIR/url.txt" | awk '{print $2}' | tr -d '"'\' || true)

  clear
  echo -e "${GREEN}====== 修改 Tuic 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port 

  local auth_uuid
  read -rp "设置 Tuic 验证 UUID [当前: ${old_uuid}, 回车不修改]: " auth_uuid
  auth_uuid=${auth_uuid:-$old_uuid}

  local auth_pwd
  read -rp "设置 Tuic 验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local cert_path key_path tuic_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    tuic_domain="$old_sni"
  fi

  write_and_show_config
  info "配置与防火墙转发修改成功！"
}

showconf() {
  if [[ ! -d "$TUIC_DIR" ]]; then
    error "未找到节点配置文件。"
    return
  fi
  echo -e "${GREEN}====== 节点分享与配置信息 ======${RESET}"
  cat "$TUIC_DIR/url.txt"
  echo
}

# =========================================================
# 7. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_tuic_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       Tuic v5 管理面板         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "端口   : ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Tuic${RESET}"
    echo -e "${GREEN}2. 更新 Tuic${RESET}"
    echo -e "${GREEN}3. 卸载 Tuic${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Tuic${RESET}"
    echo -e "${GREEN}6. 停止 Tuic${RESET}"
    echo -e "${GREEN}7. 重启 Tuic${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${0}. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) insttuic; pause ;;
      2) update_tuic; pause ;;
      3) unsthysteria; rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt" 2>/dev/null; unsttuic; pause ;;
      4) changeconf; pause ;;
      5) systemctl start tuic-server && info "服务已成功启动！"; pause ;;
      6) systemctl stop tuic-server && info "服务已成功停止！"; pause ;;
      7) systemctl restart tuic-server && info "服务已成功重启！"; pause ;;
      8) journalctl -u tuic-server.service -n 50 --no-pager; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
