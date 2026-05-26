#!/usr/bin/env bash
#
# Hysteria 2 终极一体化管理面板
# SPDX-License-Identifier: MIT
#

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly HY_CONFIG="/etc/hysteria/config.yaml"
readonly HY_BINARY="/usr/local/bin/hysteria"
readonly HY_DIR="/root/hy"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/hysteria"
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
HYSTERIA_USER="${HYSTERIA_USER:-}"
HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-}"

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
  command mktemp "$@" "hyservinst.XXXXXXXXXX"
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
  echo "正在安装缺失的依赖 '$_package_name' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    error "无法通过包管理器安装 '$_package_name'，请手动安装。"
    exit 65
  fi
}

is_user_exists() { id "$1" > /dev/null 2>&1; }

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
    'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='arm' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    's390x') ARCHITECTURE='s390x' ;;
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
    # 兼容多种格式输出，精准提取 vX.X.X
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null || "$EXECUTABLE_INSTALL_PATH" -v 2>/dev/null || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases/latest" -o "$_tmpfile"; then
    echo ""
    rm -f "$_tmpfile"
    return
  fi
  local _latest_version=$(grep 'tag_name' "$_tmpfile" | head -1 | grep -o '"app/v.*"')
  _latest_version=${_latest_version#'"app/'}
  _latest_version=${_latest_version%'"'}
  echo "$_latest_version"
  rm -f "$_tmpfile"
}

download_hysteria() {
  local _version="$1"
  local _destination="$2"
  local _download_url="$REPO_URL/releases/download/app/$_version/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
  info "正在下载官方 Hysteria 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_hysteria_server_service_base() {
  local _config_name="$1"
  cat << EOF
[Unit]
Description=Hysteria Server Service (${_config_name}.yaml)
After=network.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH server --config ${CONFIG_DIR}/${_config_name}.yaml
WorkingDirectory=$HYSTERIA_HOME_DIR
User=$HYSTERIA_USER
Group=$HYSTERIA_USER
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 面板辅助网络与配置扩展函数
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

get_hy_status() {
  if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    echo -e "${RED}● 未运行${RESET}"
  fi
}

get_current_port_display() {
  if [[ -f "$HY_CONFIG" ]]; then
    local main_port jump_range
    main_port=$(grep -E '^listen:' "$HY_CONFIG" | awk -F ':' '{print $3}' | tr -d ' ')
    if [[ -f "$HY_DIR/hy-client.yaml" ]]; then
      jump_range=$(grep -E '^server:' "$HY_DIR/hy-client.yaml" | awk -F ',' '{print $2}' | tr -d ' ')
      [[ -n "$jump_range" ]] && echo "${main_port} [${jump_range}]" && return
    fi
    echo "${main_port:- -}"
  else echo "-"; fi
}

# =========================================================
# 4. 面板核心交互逻辑 (证书 / 端口群)
# =========================================================
inst_cert() {
  echo "---------------------------------------------"
  echo -e "Hysteria 2 协议证书申请方式如下："
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
      hy_domain=$(cat /root/ca.log)
      info "检测到原有域名 [${hy_domain}] 的证书，正在复用..."
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
        hy_domain=$domain
      else
        error "Acme 证书申请失败，自动切换回自签模式。"
        certInput=1
      fi
    fi
  elif [[ $certInput == 3 ]]; then
    read -rp "请输入公钥文件 crt 的路径: " cert_path
    read -rp "请输入密钥文件 key 的路径: " key_path
    read -rp "请输入证书对应的域名: " hy_domain
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 Hysteria 2 的节点证书"
    mkdir -p /etc/hysteria
    cert_path="/etc/hysteria/cert.crt"
    key_path="/etc/hysteria/private.key"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    chmod 644 "$cert_path" "$key_path"
    hy_domain="www.bing.com"
  fi
}

inst_port() {
  local default_port=""
  [[ -f "$HY_CONFIG" ]] && default_port=$(grep -E '^listen:' "$HY_CONFIG" | awk -F ':' '{print $3}' | tr -d ' ')

  local prompt_msg="设置 Hysteria 2 主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 Hysteria 2 主端口 [当前: ${default_port}, 回车不修改]: "

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
  echo -e "Hysteria 2 端口群使用模式："
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
  jumpInput=${jumpInput:-2}

  iptables -t nat -F PREROUTING >/dev/null 2>&1 || true
  ip6tables -t nat -F PREROUTING >/dev/null 2>&1 || true

  if [[ $jumpInput == 2 ]]; then
    while true; do
      read -rp "设置起始端口 (建议10000-65535): " firstport
      read -rp "设置末尾端口 (必须大于起始端口): " endport
      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then break
      else error "输入无效，起始端口必须小于末尾端口，请重新输入。"; fi
    done
    iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
    ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
    has_command netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
    info "已成功配置端口跳跃规则: $firstport-$endport -> $port"
  else
    firstport="" && endport=""
    info "将继续使用单端口模式"
  fi
}

write_and_show_config() {
  local HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)

  cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

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
  [[ -n "${firstport}" ]] && last_port="$port,$firstport-$endport"
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  mkdir -p "$HY_DIR"
  
  cat << EOF > "$HY_DIR/hy-client.yaml"
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $hy_domain
  insecure: true
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

  cat << EOF > "$HY_DIR/url.txt"
V2rayN配置:
hysteria2://$auth_pwd@$last_ip:$port?insecure=1&sni=$hy_domain#$HOSTNAME

Surge配置:
$HOSTNAME = hysteria2, $last_ip, $port, password=$auth_pwd, skip-cert-verify=true, sni=$hy_domain
EOF

  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1 || true
  systemctl restart hysteria-server >/dev/null 2>&1 || true

  if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    info "Hysteria 2 服务配置并启动成功！"
  else
    error "Hysteria 2 服务启动失败，请运行 'systemctl status hysteria-server' 查看日志。"
  fi
  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================
insthysteria() {
  check_environment
  
  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  if [[ -z "$latest_version" ]]; then
    error "无法获取最新版本号，请检查网络设置。"
    return 1
  fi
  
  local _tmpfile=$(mktemp)
  if ! download_hysteria "$latest_version" "$_tmpfile"; then
    rm -f "$_tmpfile" && return 1
  fi

  echo -ne "正在安装二进制可执行文件 ... "
  if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -f "$_tmpfile" && error "安装失败" && return 1
  fi
  rm -f "$_tmpfile"

  HYSTERIA_USER="hysteria"
  HYSTERIA_HOME_DIR="/var/lib/hysteria"
  if ! is_user_exists "$HYSTERIA_USER"; then
    echo -ne "正在创建系统独立沙箱运行用户 $HYSTERIA_USER ... "
    useradd -r -d "$HYSTERIA_HOME_DIR" -m "$HYSTERIA_USER" >/dev/null 2>&1 || true
    echo "成功"
  fi

  install_content -Dm644 "$(tpl_hysteria_server_service_base 'config')" "$SYSTEMD_SERVICES_DIR/hysteria-server.service" "1"
  install_content -Dm644 "$(tpl_hysteria_server_service_base '%i')" "$SYSTEMD_SERVICES_DIR/hysteria-server@.service" "1"

  firstport="" && endport=""
  inst_cert || return 1
  inst_port
  
  read -rp "设置 Hysteria 2 验证密码 (回车自动分配随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}
  
  read -rp "请输入 Hysteria 2 的伪装网站地址 (默认: en.snu.ac.kr): " proxysite
  proxysite=${proxysite:-"en.snu.ac.kr"}

  write_and_show_config
}

update_hysteria() {
  if [[ ! -f "$HY_BINARY" ]]; then
    error "当前系统未安装 Hysteria 2，无法执行更新。"
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

  warn "检测到新版本，即将开始平滑更新 (你的配置与端口规则不会改变)..."
  
  local _tmpfile=$(mktemp)
  if ! download_hysteria "$latest_version" "$_tmpfile"; then
    rm -f "$_tmpfile" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -f "$_tmpfile" && error "覆盖核心失败" && return 1
  fi
  rm -f "$_tmpfile"

  info "正在重启 Hysteria 2 服务以应用更新..."
  systemctl daemon-reload
  systemctl restart hysteria-server >/dev/null 2>&1 || true

  if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    info "Hysteria 2 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
  else
    error "核心更新成功，但服务重启失败，请运行 'systemctl status hysteria-server' 检查错误。"
  fi
}

unsthysteria() {
  warn "即将从当前系统中彻底卸载 Hysteria 2"

  systemctl stop hysteria-server >/dev/null 2>&1 || true
  systemctl disable hysteria-server >/dev/null 2>&1 || true
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server.service"
  remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"
  
  systemctl daemon-reload
  rm -rf /etc/hysteria "$HY_DIR"
  
  iptables -t nat -F PREROUTING >/dev/null 2>&1 || true
  ip6tables -t nat -F PREROUTING >/dev/null 2>&1 || true
  has_command netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true

  info "Hysteria 2 已彻底从您的系统中移除！"
}

changeconf() {
  if [[ ! -f "$HY_CONFIG" ]]; then
    error "配置文件不存在，请先安装 Hysteria 2"
    return 1
  fi

  local old_pwd=$(grep -E '^\s*password:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\' || true)
  local old_cert=$(grep -E '^\s*cert:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\' || true)
  local old_key=$(grep -E '^\s*key:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\' || true)
  local old_site=$(grep -E '^\s*url:' "$HY_CONFIG" | awk '{print $2}' | sed 's#https://##' | tr -d '"'\' || true)
  local old_sni="www.bing.com"
  [[ -f "$HY_DIR/hy-client.yaml" ]] && old_sni=$(grep -E '^\s*sni:' "$HY_DIR/hy-client.yaml" | awk '{print $2}' | tr -d '"'\' || true)

  clear
  echo -e "${GREEN}====== 修改 Hysteria 2 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  firstport="" && endport=""
  inst_port 

  local auth_pwd
  read -rp "设置 Hysteria 2 密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local cert_path key_path hy_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    hy_domain="$old_sni"
  fi

  local proxysite
  echo "---------------------------------------------"
  read -rp "请输入新的伪装网站地址 [当前: ${old_site}, 回车不修改]: " proxysite
  proxysite=${proxysite:-$old_site}

  write_and_show_config
  info "配置修改并应用成功！"
}

showconf() {
  if [[ ! -d "$HY_DIR" ]]; then
    error "未找到客户端配置文件。"
    return
  fi
  echo -e "${GREEN}====== 客户端 YAML 配置 ======${RESET}"
  cat "$HY_DIR/hy-client.yaml"
  echo
  echo -e "${GREEN}====== 节点分享链接 ======${RESET}"
  cat "$HY_DIR/url.txt"
  echo
}

# =========================================================
# 6. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_hy_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "状态   : $status"
    echo -e "版本   : ${YELLOW}${version}${RESET}"
    echo -e "端口   : ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Hysteria 2${RESET}"
    echo -e "${GREEN}2. 更新 Hysteria 2${RESET}"
    echo -e "${GREEN}3. 卸载 Hysteria 2${RESET}"
    echo -e "${GREEN}4. 启动 Hysteria 2${RESET}"
    echo -e "${GREEN}5. 关闭 Hysteria 2${RESET}"
    echo -e "${GREEN}6. 重启 Hysteria 2${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 修改配置 (端口/证书/密码/伪装)${RESET}"
    echo -e "${GREEN}9. 查看配置文件与链接${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) insthysteria; pause ;;
      2) update_hysteria; pause ;;
      3) unsthysteria; pause ;;
      4) systemctl start hysteria-server && info "服务已成功启动！"; pause ;;
      5) systemctl stop hysteria-server && info "服务已成功停止！"; pause ;;
      6) systemctl restart hysteria-server && info "服务已成功重启！"; pause ;;
      7) journalctl -u hysteria-server.service -f; pause ;;
      8) changeconf; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
