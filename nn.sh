#!/usr/bin/env bash
#
# Tuic 管理面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly TUIC_CONFIG="/etc/tuic/server.json"
readonly BINARY_PATH="/usr/local/bin/tuic-server"
readonly TUIC_DIR="/root/tuic"
CONFIG_DIR="/etc/tuic"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
REPO_URL="https://github.com/EAimTY/tuic"
API_BASE_URL="https://api.github.com/repos/EAimTY/tuic"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境依赖变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# =========================================================
# 2. 系统底层工具函数
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

install_packages() {
  has_command curl || install_software curl
  has_command wget || install_software wget
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command openssl || install_software openssl
  has_command iptables || install_software iptables
}

detect_arch() {
  case "$(uname -m)" in
    'x86_64' | 'amd64') echo "x86_64-unknown-linux-gnu" ;;
    'aarch64' | 'arm64') echo "aarch64-unknown-linux-gnu" ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac
}

check_environment() {
  if [[ "x$(uname)" != "xLinux" ]]; then
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi
  install_packages
}

get_installed_version() {
  if [[ -f "$BINARY_PATH" ]]; then
    local version_out
    version_out=$("$BINARY_PATH" -v 2>/dev/null || "$BINARY_PATH" --version 2>/dev/null || echo "")
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
    return 1
  fi
  local _raw_tag=$(jq -r '[.[] | select(.prerelease==false and (.assets[].name | contains("tuic-server")))] | first | .tag_name' "$_tmpfile")
  echo "$_raw_tag"
  rm -f "$_tmpfile"
}

# =========================================================
# 3. iptables 规则持久化与转发控制模块
# =========================================================
ensure_iptables_persistent() {
  if has_command dpkg; then
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
      info "正在安装 iptables-persistent 以确保重启后规则不丢失..."
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
      install_software iptables-persistent || warn "安装持久化工具失败，规则可能在重启后失效"
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

apply_new_iptables() {
  clear_old_iptables
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    
    info "正在应用 iptables 转发规则: UDP $start_p-$end_p => 主端口 $port"
    iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port"
    ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    
    echo "$port" > "${CONFIG_DIR}/main_port.txt"
    save_iptables_rules
  fi
}

# =========================================================
# 4. 网络诊断与配置管理辅助
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
    main_port=$(jq -r '.server' "$TUIC_CONFIG" 2>/dev/null | awk -F':' '{print $NF}' || echo "")
    [[ -z "$main_port" || "$main_port" == "null" ]] && main_port=$(jq -r '.port' "$TUIC_CONFIG" 2>/dev/null || echo "")
    [[ -f "${CONFIG_DIR}/hopping.txt" ]] && jump_range=$(cat "${CONFIG_DIR}/hopping.txt")
    
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "-"; fi
}

# =========================================================
# 5. 面板节点配置生成核心逻辑 (已经过对齐重构)
# =========================================================
inst_cert() {
  # 【修复核心1】只要进入证书环节，无条件前置初始化目录
  mkdir -p /etc/tuic

  echo "---------------------------------------------"
  echo -e "Tuic 协议证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme 脚本自动申请 (需放行 80 端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  # 【修复核心2】标准化全局隔离路径，打破外部目录权限壁垒
  cert_path="/etc/tuic/cert.crt"
  key_path="/etc/tuic/private.key"

  if [[ $certInput == 2 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。请确保已暂时关闭 Web 服务。"
    fi

    if [[ -f /etc/tuic/cert.crt && -f /etc/tuic/private.key && -s /etc/tuic/cert.crt && -s /etc/tuic/private.key && -f /etc/tuic/ca.log ]]; then
      tuic_domain=$(cat /etc/tuic/ca.log)
      info "检测到已有域名 [${tuic_domain}] 的安全区证书，正在复用..."
    else
      local vps_ip=$(get_public_ip)
      read -rp "请输入需要申请证书的域名: " domain
      [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
      
      info "正在检查并安装 Acme.sh 依赖..."
      local acme_cmd="/root/.acme.sh/acme.sh"
      if [[ ! -f "$acme_cmd" ]]; then
        curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
      fi
      
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      info "正在向 Let's Encrypt 申请证书..."
      if [[ "$vps_ip" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      
      # 直接下发分发指令，安全安装到内部高特权隔离路径中
      if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
        echo "$domain" > /etc/tuic/ca.log
        tuic_domain=$domain
        info "Acme 证书申请并成功分发至安全沙箱！"
      else
        error "Acme 证书申请失败，自动切换回自签模式。"
        certInput=1
      fi
    fi
  elif [[ $certInput == 3 ]]; then
    local user_cert user_key
    read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
    read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
    read -rp "请输入证书对应的域名: " tuic_domain
    
    if [[ -f "$user_cert" && -f "$user_key" ]]; then
      # 深度同名复制解耦，规避父级家目录 Permission Denied
      cp -f "$user_cert" "$cert_path"
      cp -f "$user_key" "$key_path"
      info "自定义证书已成功同步解耦至内部安全区。"
    else
      error "找不到输入的证书文件，自动降级回自签模式。"
      certInput=1
    fi
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 Tuic 的节点证书"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    tuic_domain="www.bing.com"
  fi

  # 强力锁紧证书本身的文件权限
  chmod 644 "$cert_path"
  chmod 600 "$key_path"
}

inst_port() {
  local default_port=""
  if [[ -f "$TUIC_CONFIG" ]]; then
    default_port=$(jq -r '.server' "$TUIC_CONFIG" 2>/dev/null | awk -F':' '{print $NF}' || echo "")
    [[ -z "$default_port" || "$default_port" == "null" ]] && default_port=$(jq -r '.port' "$TUIC_CONFIG" 2>/dev/null || echo "")
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
  echo -e "Tuic 端口群使用模式 ："
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
  jumpInput=${jumpInput:-2}

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

  cat << EOF > /etc/tuic/server.json
{
  "server": "[::]:$port",
  "certificate": "$cert_path",
  "private_key": "$key_path",
  "users": {
    "$auth_uuid": "$auth_pwd"
  },
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "log_level": "info"
}
EOF

  apply_new_iptables

  mkdir -p "$TUIC_DIR"
  
  local hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  cat << EOF > "$TUIC_DIR/url.txt"
V2rayN 链接:
tuic://$auth_uuid:$auth_pwd@$last_ip:$port?alpn=h3&congestion_control=bbr&sni=$tuic_domain&allow_insecure=1${hopping_param}#$HOSTNAME-tuicv5

Surge 配置:
$HOSTNAME-tuicv5 = tuic-v5, $last_ip, $port, password=$auth_pwd, uuid=$auth_uuid, ecn=true, skip-cert-verify=true, sni=$tuic_domain

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
# 6. 安装、更新与卸载核心流控
# =========================================================
install_tuic() {
  echo -e "${GREEN}[信息] 开始安装 Tuic V5 ...${RESET}"
  check_environment
  mkdir -p "$TUIC_DIR"

  local arch raw_tag pure_version url
  arch=$(detect_arch)
  
  echo -e "${GREEN}[信息] 正在动态获取 Tuic 最新版本...${RESET}"
  raw_tag=$(get_latest_version)
  
  if [[ -z "$raw_tag" || "$raw_tag" == "null" ]]; then
    echo -e "${RED}[错误] 无法获取最新版本号，请检查网络设置。${RESET}"
    return 1
  fi
  
  pure_version=${raw_tag#tuic-server-}
  echo -e "${GREEN}[信息] 检测到最新版本 Tag 为: ${raw_tag} (版本号: v${pure_version})${RESET}"
  
  url="https://github.com/EAimTY/tuic/releases/download/${raw_tag}/tuic-server-${pure_version}-${arch}"

  echo -e "${GREEN}[信息] 开始下载 Tuic 服务端到 /usr/local/bin ...${RESET}"
  echo -e "${BLUE}[下载路径] ${url}${RESET}"
  
  if ! wget -O "$BINARY_PATH" -q "$url"; then
    echo -e "${YELLOW}[警告] wget 下载失败，尝试切换到 curl...${RESET}"
    curl -fsSL -o "$BINARY_PATH" "$url" || { echo -e "${RED}[错误] 核心程序下载失败，请检查网络${RESET}"; return 1; }
  fi
  
  chmod +x "$BINARY_PATH"
  echo -e "${GREEN}[信息] Tuic 核心下载并安装成功。${RESET}"

  mkdir -p "$CONFIG_DIR"
  cat << EOF > "$SYSTEMD_SERVICES_DIR/tuic-server.service"
[Unit]
Description=Tuic Server Service
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH --config $TUIC_CONFIG
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  inst_cert || return 1
  inst_port
  
  read -rp "设置 Tuic 验证 UUID (回车自动分配随机 UUID): " auth_uuid
  auth_uuid=${auth_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "12345678-1234-1234-1234-123456781234")}
  
  read -rp "设置 Tuic 验证密码 (回车自动分配随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_tuic() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未安装 Tuic，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local raw_tag=$(get_latest_version)

  if [[ -z "$raw_tag" || "$raw_tag" == "null" ]]; then
    error "无法连接到 GitHub API 获取最新版本，请稍后再试。"
    return 1
  fi

  local pure_version=${raw_tag#tuic-server-}
  info "当前安装版本: ${YELLOW}${current_version}${RESET}"
  info "官方最新版本: ${GREEN}${pure_version}${RESET}"

  if [[ "$current_version" == "$pure_version" ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "检测到新版本，即将开始平滑更新 (原有防火墙转发及配置不受损)..."
  
  local arch=$(detect_arch)
  local url="https://github.com/EAimTY/tuic/releases/download/${raw_tag}/tuic-server-${pure_version}-${arch}"
  local _tmpfile=$(mktemp)

  if ! curl -fsSL -o "$_tmpfile" "$url"; then
    error "下载核心失败！"
    rm -f "$_tmpfile" && return 1
  fi

  systemctl stop tuic-server >/dev/null 2>&1 || true
  if cp "$_tmpfile" "$BINARY_PATH" && chmod +x "$BINARY_PATH"; then
    info "核心覆盖成功！"
  else
    error "覆盖核心失败"
    rm -f "$_tmpfile" && return 1
  fi
  rm -f "$_tmpfile"

  info "正在重启 Tuic 服务..."
  systemctl restart tuic-server >/dev/null 2>&1 || true

  if systemctl is-active --quiet tuic-server 2>/dev/null; then
    info "Tuic 已成功更新至 ${GREEN}v${pure_version}${RESET}！"
  else
    error "核心更新成功，但服务重启失败，请检查日志。"
  fi
}

unsttuic() {
  warn "即将从当前系统中彻底卸载 Tuic 并清理防火墙转发规则"

  clear_old_iptables
  save_iptables_rules

  systemctl stop tuic-server >/dev/null 2>&1 || true
  systemctl disable tuic-server >/dev/null 2>&1 || true
  
  rm -f "$BINARY_PATH"
  rm -f "$SYSTEMD_SERVICES_DIR/tuic-server.service"
  
  systemctl daemon-reload
  rm -rf /etc/tuic "$TUIC_DIR"
  
  info "Tuic 已彻底卸载"
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
# 7. 面板交互菜单
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
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
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
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_tuic; pause ;;
      2) update_tuic; pause ;;
      3) rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt" 2>/dev/null; unsttuic; pause ;;
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
