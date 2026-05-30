#!/usr/bin/env bash
#
# Tuicv5 Alpine (OpenRC) 专属管理面板 - 终极修复版
# SPDX-License-Identifier: MIT
#

set -Eo pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly TUIC_CONFIG="/etc/tuic/server.json"
readonly BINARY_PATH="/usr/local/bin/tuic-server"
readonly TUIC_DIR="/root/tuicV5"
CONFIG_DIR="/etc/tuic"
INIT_SERVICE="/etc/init.d/tuic-server"
TUIC_LOG="/var/log/tuic-server.log"
REPO_URL="https://github.com/EAimTY/tuic"
API_BASE_URL="https://api.github.com/repos/EAimTY/tuic"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
RESET="\033[0m"

# =========================================================
# 2. 系统底层工具函数
# =========================================================
has_command() {
  type -P "$1" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
  head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16
}

install_packages() {
  echo -e "${BLUE}正在检查并部署 Alpine 基础依赖项...${RESET}"
  if ! apk update; then
    warn "更新 apk 索引失败，尝试直接安装..."
  fi
  apk add --no-cache curl wget grep jq openssl iptables ip6tables openrc bash
}

detect_arch() {
  case "$(uname -m)" in
    'x86_64' | 'amd64') echo "x86_64-unknown-linux-gnu" ;;
    'aarch64' | 'arm64') echo "aarch64-unknown-linux-gnu" ;;
    *) echo "x86_64-unknown-linux-gnu" ;; # 容错托底
  esac
}

get_installed_version() {
  if [[ -f "$BINARY_PATH" ]]; then
    local version_out
    version_out=$("$BINARY_PATH" -v 2>&1 || "$BINARY_PATH" --version 2>&1 || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "已安装"
    else
      echo "已安装"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile
  _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases" -o "$_tmpfile"; then
    echo ""
    rm -f "$_tmpfile"
    return 1
  fi
  local _raw_tag
  _raw_tag=$(jq -r '[.[] | select(.prerelease==false and (.assets[].name | contains("tuic-server")))] | first | .tag_name' "$_tmpfile" 2>/dev/null || echo "")
  echo "$_raw_tag"
  rm -f "$_tmpfile"
}

# =========================================================
# 3. iptables 防火墙持久化模块（适配 Alpine）
# =========================================================
save_iptables_rules() {
  if [ -f "/etc/init.d/iptables" ]; then
    rc-service iptables save >/dev/null 2>&1 || true
  fi
  if [ -f "/etc/init.d/ip6tables" ]; then
    rc-service ip6tables save >/dev/null 2>&1 || true
  fi
}

clear_old_iptables() {
  if [[ -f "${CONFIG_DIR}/hopping.txt" && -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local old_hop old_port old_start old_end
    old_hop=$(cat "${CONFIG_DIR}/hopping.txt")
    old_port=$(cat "${CONFIG_DIR}/main_port.txt")
    old_start=${old_hop%-*}
    old_end=${old_hop#*-}

    if [[ -n "$old_start" && -n "$old_end" && -n "$old_port" ]]; then
      iptables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      ip6tables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
    fi
  fi
}

apply_new_iptables() {
  clear_old_iptables
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val start_p end_p
    hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    start_p=${hop_val%-*}
    end_p=${hop_val#*-}
    
    info "正在应用 Alpine iptables 转发规则: UDP $start_p-$end_p => 主端口 $port"
    iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
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
  for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
    ip=$(curl -s --max-time 5 "$url" || wget -T 5 -qO- "$url" || true)
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $ip =~ : ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "127.0.0.1"
}

check_port() {
  local port="$1"
  if netstat -an 2>/dev/null | grep -w "udp" | grep -E "[:\.]${port} " | grep -q -i "listen"; then
    return 1
  fi
  return 0
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_random_port() {
  local rand_port
  while true; do
    rand_port=$(awk 'BEGIN{srand(); print int(rand()*(65535-2000+1))+2000}')
    if check_port "$rand_port"; then
      echo "$rand_port" && return 0
    fi
  done
}

get_tuic_status() {
  if pidof tuic-server >/dev/null 2>&1 || rc-service tuic-server status 2>/dev/null | grep -qi "started"; then
    echo -e "${GREEN}● 运行中 (OpenRC)${RESET}"
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
# 5. 证书与端口配置
# =========================================================
inst_cert() {
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

  cert_path="/etc/tuic/cert.crt"
  key_path="/etc/tuic/private.key"

  if [[ $certInput == 2 ]]; then
    if netstat -an | grep -w "tcp" | grep -q ":80 "; then
      warn "检测到 80 端口已被占用，请确保已暂时关闭 Web 服务。"
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
        curl https://get.acme.sh | sh -s email=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 10)@gmail.com
      fi
      
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      info "正在向 Let's Encrypt 申请证书..."
      if [[ "$vps_ip" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      
      if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
        echo "$domain" > /etc/tuic/ca.log
        tuic_domain=$domain
        info "Acme 证书申请并成功分发！"
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
      cp -f "$user_cert" "$cert_path"
      cp -f "$user_key" "$key_path"
      info "自定义证书已成功同步。"
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
  local HOSTNAME vps_ip last_ip is_insecure skip_cert hopping_param
  # 安全获取主机名，防范 Alpine 空变量中断
  HOSTNAME=$(hostname 2>/dev/null || echo "alpine-vps")
  HOSTNAME=$(echo "$HOSTNAME" | sed 's/ /_/g')
  
  vps_ip=$(get_public_ip)
  last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  is_insecure="0"
  skip_cert="false"
  if [[ "$tuic_domain" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

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
  
  hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  cat << EOF > "$TUIC_DIR/url.txt"
V6VPS 请自行替换 IP 地址为 V6
V2rayN 链接:
tuic://$auth_uuid:$auth_pwd@$last_ip:$port?alpn=h3&congestion_control=bbr&sni=$tuic_domain&allow_insecure=${is_insecure}${hopping_param}#$HOSTNAME-tuicv5

Surge 配置:
$HOSTNAME-tuicv5 = tuic-v5, $last_ip, $port, password=$auth_pwd, uuid=$auth_uuid, ecn=true, skip-cert-verify=${skip_cert}, sni=$tuic_domain

Clash Meta / Mihomo 格式备忘:
- name: $HOSTNAME-tuic
  type: tuic
  server: $vps_ip
  port: $port
  uuid: $auth_uuid
  password: $auth_pwd
  alpn: [h3]
  sni: $tuic_domain
  skip-cert-verify: ${skip_cert}
EOF

  if [ -f "$INIT_SERVICE" ]; then
    rc-service tuic-server restart >/dev/null 2>&1 || true
  fi
  showconf
}

# =========================================================
# 6. 安装、更新与卸载核心流控 (OpenRC 专设)
# =========================================================
install_tuic() {
  if [ -f "$BINARY_PATH" ]; then
    echo -e "${YELLOW}[提示] 检测到系统中已安装 Tuic 核心。如需改配请使用选项 4。${RESET}"
    return 0
  fi

  info "开始安装 Alpine 专属 Tuic V5 ..."
  install_packages
  mkdir -p "$TUIC_DIR"

  local arch raw_tag pure_version url
  arch=$(detect_arch)
  
  info "正在动态获取 Tuic 最新版本..."
  raw_tag=$(get_latest_version)
  
  if [[ -z "$raw_tag" || "$raw_tag" == "null" ]]; then
    error "无法获取最新版本号，请检查 Alpine 网络与 DNS 设置。"
    return 1
  fi
  
  pure_version=${raw_tag#tuic-server-}
  info "检测到最新版本: v${pure_version}"
  
  url="https://github.com/EAimTY/tuic/releases/download/${raw_tag}/tuic-server-${pure_version}-${arch}"
  info "开始下载核心程序..."
  
  if ! wget -O "$BINARY_PATH" -q "$url"; then
    curl -fsSL -o "$BINARY_PATH" "$url" || { error "核心程序下载失败！"; return 1; }
  fi
  
  chmod +x "$BINARY_PATH"
  mkdir -p "$CONFIG_DIR"

  cat << 'EOF' > "$INIT_SERVICE"
#!/sbin/openrc-run

name="Tuic Server"
description="Tuic v5 High-performance Proxy Service"
command="/usr/local/bin/tuic-server"
command_args="--config /etc/tuic/server.json"
pidfile="/var/run/tuic-server.pid"
command_background="yes"
output_log="/var/log/tuic-server.log"
error_log="/var/log/tuic-server.log"

depend() {
    need net
    after firewall iptables ip6tables
}
EOF
  chmod +x "$INIT_SERVICE"
  rc-update add tuic-server default >/dev/null 2>&1 || true

  inst_cert || return 1
  inst_port
  
  read -rp "设置 Tuic 验证 UUID (回车自动随机化): " auth_uuid
  auth_uuid=${auth_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head /dev/urandom | tr -dc 'a-f0-9' | head -c 32 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')}
  
  read -rp "设置 Tuic 验证密码 (回车自动随机化): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_tuic() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未安装 Tuic，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version raw_tag pure_version arch url _tmpfile
  current_version=$(get_installed_version)
  raw_tag=$(get_latest_version)

  if [[ -z "$raw_tag" || "$raw_tag" == "null" ]]; then
    error "无法连接到 GitHub API，请稍后再试。"
    return 1
  fi

  pure_version=${raw_tag#tuic-server-}
  info "当前版本: ${YELLOW}${current_version}${RESET} | 最新版本: ${GREEN}${pure_version}${RESET}"

  if [[ "$current_version" == "$pure_version" ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "开始平滑更新核心..."
  arch=$(detect_arch)
  url="https://github.com/EAimTY/tuic/releases/download/${raw_tag}/tuic-server-${pure_version}-${arch}"
  _tmpfile=$(mktemp)

  if ! curl -fsSL -o "$_tmpfile" "$url"; then
    error "下载新核心失败！"
    rm -f "$_tmpfile" && return 1
  fi

  rc-service tuic-server stop >/dev/null 2>&1 || true
  if cp "$_tmpfile" "$BINARY_PATH" && chmod +x "$BINARY_PATH"; then
    info "核心替换成功！"
  else
    error "核心覆盖失败！"
    rm -f "$_tmpfile" && return 1
  fi
  rm -f "$_tmpfile"

  rc-service tuic-server start >/dev/null 2>&1 || true
  info "Tuic 已成功更新至 v${pure_version}！"
}

unsttuic() {
  warn "正在从 Alpine 系统中彻底卸载 Tuic 并清理防火墙..."
  clear_old_iptables
  save_iptables_rules

  if [ -f "$INIT_SERVICE" ]; then
    rc-service tuic-server stop >/dev/null 2>&1 || true
    rc-update del tuic-server default >/dev/null 2>&1 || true
    rm -f "$INIT_SERVICE"
  fi
  
  rm -f "$BINARY_PATH"
  rm -rf /etc/tuic "$TUIC_DIR" "$TUIC_LOG"
  info "Tuic 已经彻底卸载！"
}

changeconf() {
  if [[ ! -f "$TUIC_CONFIG" ]]; then
    error "配置文件不存在，请先安装 Tuic"
    return 1
  fi

  local old_uuid old_pwd old_cert old_key old_sni change_cert_flag
  old_uuid=$(jq -r '.users | keys[0]' "$TUIC_CONFIG" 2>/dev/null || echo "")
  old_pwd=$(jq -r ".users.\"$old_uuid\"" "$TUIC_CONFIG" 2>/dev/null || echo "")
  old_cert=$(jq -r '.certificate' "$TUIC_CONFIG" 2>/dev/null || echo "")
  old_key=$(jq -r '.private_key' "$TUIC_CONFIG" 2>/dev/null || echo "")
  old_sni="www.bing.com"
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
  info "配置及 OpenRC 转发应用成功！"
}

showconf() {
  if [[ ! -f "$TUIC_DIR/url.txt" ]]; then
    error "未找到任何可用节点配置文件，或因环境异常未成功生成。"
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
  if [ "$(id -u)" -ne 0 ]; then
    error "请切换至 root 用户运行此面板脚本。"
    exit 1
  fi

  while true; do
    clear
    local status version port_show
    status=$(get_tuic_status)
    version=$(get_installed_version)
    port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Tuic v5 Alpine 专属面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Tuicv5${RESET}"
    echo -e "${GREEN}2. 更新 Tuicv5${RESET}"
    echo -e "${GREEN}3. 卸载 Tuicv5${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Tuicv5${RESET}"
    echo -e "${GREEN}6. 停止 Tuicv5${RESET}"
    echo -e "${GREEN}7. 重启 Tuicv5${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
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
      5) rc-service tuic-server start >/dev/null 2>&1 || true; info "启动指令已成功下发。"; sleep 1; pause ;;
      6) rc-service tuic-server stop >/dev/null 2>&1 || true; info "服务已成功挂起停止。"; sleep 1; pause ;;
      7) rc-service tuic-server restart >/dev/null 2>&1 || true; info "服务已成功完成重启。"; sleep 1; pause ;;
      8) 
        if [ -f "$TUIC_LOG" ]; then
          echo -e "${PURPLE}=== 最新 50 行本地系统日志 ===${RESET}"
          tail -n 50 "$TUIC_LOG"
        else
          echo -e "${YELLOW}暂无可用运行日志输出。${RESET}"
        fi
        pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
