#!/usr/bin/env bash
#
# sing-box (AnyTLS) 核心控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly SB_CONFIG="/etc/mo-anytls-sb/config.json"
readonly SB_BINARY="/usr/local/bin/sing-box"
readonly SB_DIR="/root/proxynode/Anytls"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/mo-anytls-sb"
REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
SINGBOX_USER="${SINGBOX_USER:-}"
SINGBOX_HOME_DIR="${SINGBOX_HOME_DIR:-}"

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
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
  # 生成 16 位强随机密码作为 AnyTLS 备用密钥
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

systemctl() {
  if ! has_command systemctl; then
    warn "当前系统不支持 systemd，忽略守护进程操作: systemctl $*"
    return 0
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
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null | head -n 1 || echo "")
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
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases/latest" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '.tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  
  if [[ -n "$_tag_name" ]]; then
    echo "${_tag_name##*v}"
  else
    echo ""
  fi
}

download_singbox() {
  local _version="$1"
  local _destination="$2"
  local _download_url="$REPO_URL/releases/download/v${_version}/sing-box-${_version}-linux-${ARCHITECTURE}.tar.gz"
  
  info "正在下载官方 sing-box 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_singbox_server_service_base() {
  local _config_name="$1"
  cat << EOF
[Unit]
Description=sing-box Server Service (${_config_name}.json)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH run --config ${CONFIG_DIR}/${_config_name}.json
WorkingDirectory=$SINGBOX_HOME_DIR
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
}

# =========================================================
# 3. 网络与配置扩展辅助函数
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
    if check_port "$rand_port"; then
      echo "$rand_port" && return 0
    fi
  done
}

get_sb_status() {
  if has_command systemctl && systemctl is-active --quiet mo-anytls-sb 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$SB_CONFIG" ]]; then
    local main_port
    main_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "")
    echo "${main_port:- -}"
  else echo "-"; fi
}

# =========================================================
# 4. 证书、端口交互与配置写入
# =========================================================
inst_cert() {
  mkdir -p /etc/mo-anytls-sb
  
  echo "---------------------------------------------"
  echo -e "sing-box TLS 证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme自动申请 (需放行80端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  cert_path="/etc/mo-anytls-sb/fullchain.pem"
  key_path="/etc/mo-anytls-sb/privkey.pem"

  if [[ $certInput == 2 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。请确保已暂时关闭 Web 服务。"
    fi

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
    
    # 【核心优化点】: 
    # 1. 判定当前的守护进程环境，生成对应的重启命令
    # 2. 使用 --reloadcmd。这样以后每次 crontab 触发自动续期成功后，Acme 会自动把新证书刷进路径，并自动重启 sing-box！
    local reload_cmd="pkill -f '$EXECUTABLE_INSTALL_PATH run' || true; '$EXECUTABLE_INSTALL_PATH' run --config /etc/mo-anytls-sb/config.json >/dev/null 2>&1 &"
    if has_command systemctl; then
      reload_cmd="systemctl restart mo-anytls-sb"
    fi

    info "正在配置证书自动同步与服务重载钩子..."
    if "$acme_cmd" --install-cert -d "${domain}" \
      --key-file "$key_path" \
      --fullchain-file "$cert_path" \
      --ecc \
      --reloadcmd "$reload_cmd"; then
      
      echo "$domain" > /etc/mo-anytls-sb/ca.log
      sb_domain=$domain
      info "Acme 证书申请成功！已建立自动续期同步与服务重启快线。"
    else
      error "Acme 证书申请失败，自动切换回自签模式。"
      certInput=1
    fi
    
  elif [[ $certInput == 3 ]]; then
    local user_cert user_key
    read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
    read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
    read -rp "请输入证书对应的域名: " sb_domain
    
    if [[ -f "$user_cert" && -f "$user_key" ]]; then
      # 【优化点】自定义证书改用软链接（ln -sf），原文件更新时，沙箱内同步生效
      rm -f "$cert_path" "$key_path"
      ln -sf "$user_cert" "$cert_path"
      ln -sf "$user_key" "$key_path"
      info "自定义证书已通过软链接同步至内部安全区。"
    else
      error "找不到输入的证书文件，自动降级回自签模式。"
      certInput=1
    fi
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 sing-box 的节点证书"
    rm -f "$cert_path" "$key_path" # 清理可能残留的软链接
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    sb_domain="www.bing.com"
  fi

  # 如果是软链接，chmod -h 和 chown -h 可以确保只修改链接本身或穿透正确
  chmod 644 "$cert_path" || true
  chmod 600 "$key_path" || true
  if is_user_exists "sing-box"; then
    chown -R sing-box:sing-box /etc/mo-anytls-sb
  fi
}

inst_port() {
  local default_port=""
  [[ -f "$SB_CONFIG" ]] && default_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "")

  local prompt_msg="设置 sing-box 主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 sing-box 主端口 [当前: ${default_port}, 回车不修改]: "

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
}

write_and_show_config() {
  local hostname=$(hostname -s | sed 's/ /_/g')
  local ip=$(get_public_ip)
  local url_ip="$ip"
  if [[ "$ip" =~ ":" ]]; then 
    url_ip="[$ip]"
  fi

  # 1. 写入服务端核心 JSON
  cat << EOF > /etc/mo-anytls-sb/config.json
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
        "server_name": "$sb_domain",
        "key_path": "$key_path",
        "certificate_path": "$cert_path"
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

  mkdir -p "$SB_DIR"
  
  # 2. 写入通用客户端 sing-box.json 备份
  cat << EOF > "$SB_DIR/sb-client.json"
{
  "log": {
    "level": "info"
  },
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-out",
      "server": "$url_ip",
      "server_port": $port,
      "password": "$auth_pwd",
      "tls": {
        "enabled": true,
        "server_name": "$sb_domain",
        "insecure": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  # 3. 固化持久化节点数据（保存为文本形式，防止转移丢失）
  cat << EOF > "$SB_DIR/url.txt"
====== AnyTLS 节点信息 ======
IP      : ${ip}
端口    : $port
密码    : $auth_pwd
---------------------------
📄 V6VPS 请自行替换 IP 地址为 V6 ★
[信息] V2rayN 链接：
anytls://$auth_pwd@$url_ip:$port/?insecure=1#$hostname-Anytls
[信息] Surge 配置：
$hostname-Anytls = anytls, $url_ip, $port, password=$auth_pwd, tfo=true, skip-cert-verify=true, reuse=false
---------------------------------
EOF

  if is_user_exists "sing-box"; then
    chown -R sing-box:sing-box /etc/mo-anytls-sb
  fi

  # 4. 守护进程分支运行
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable mo-anytls-sb >/dev/null 2>&1 || true
    systemctl restart mo-anytls-sb >/dev/null 2>&1 || true
    
    if systemctl is-active --quiet mo-anytls-sb 2>/dev/null; then
      info "sing-box (anytls) 服务配置并启动成功！"
    else
      error "sing-box 服务启动失败，请运行 'systemctl status mo-anytls-sb' 查看日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --config $SB_CONFIG >/dev/null 2>&1 &
    info "非 systemd 环境，程序已挂载至后台 Pid 进程池中运行。"
  fi
  
  showconf
}

# =========================================================
# 5. 主流程功能控制模块
# =========================================================
instsingbox() {
  check_environment
  
  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  if [[ -z "$latest_version" ]]; then
    error "无法获取最新版本号，请检查网络设置。"
    return 1
  fi
  
  local _tmparchive=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在解压并安装二进制可执行文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xzf "$_tmparchive" -C "$_tmpdir"
  
  if install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "安装失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  SINGBOX_USER="sing-box"
  SINGBOX_HOME_DIR="/var/lib/sing-box"
  if ! is_user_exists "$SINGBOX_USER"; then
    echo -ne "正在创建系统独立沙箱运行用户 $SINGBOX_USER ... "
    useradd -r -d "$SINGBOX_HOME_DIR" -m "$SINGBOX_USER" >/dev/null 2>&1 || true
    echo "成功"
  fi

  if has_command systemctl; then
    install_content -Dm644 "$(tpl_singbox_server_service_base 'config')" "$SYSTEMD_SERVICES_DIR/mo-anytls-sb.service" "1"
    install_content -Dm644 "$(tpl_singbox_server_service_base '%i')" "$SYSTEMD_SERVICES_DIR/mo-anytls-sb@.service" "1"
  fi

  inst_cert || return 1
  inst_port
  
  # 优先支持自定义密码输入，直接回车则采用 16 位强随机密码
  read -rp "设置 AnyTLS 验证密码 (直接回车将自动分配强随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$SB_BINARY" ]]; then
    error "当前系统未安装 sing-box，无法执行更新。"
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

  warn "检测到新版本，即将开始平滑更新 (你的配置与运行数据不会改变)..."
  
  local _tmparchive=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xzf "$_tmparchive" -C "$_tmpdir"
  if install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  info "正在重启 sing-box 服务以应用更新..."
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl restart mo-anytls-sb >/dev/null 2>&1 || true
    if systemctl is-active --quiet mo-anytls-sb 2>/dev/null; then
      info "sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但服务重启失败，请运行 'systemctl status mo-anytls-sb' 检查错误。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
    info "sing-box 核心已更新并于后台重启运行。"
  fi
}

unstsingbox() {
  warn "即将从当前系统中彻底卸载 sing-box"

  if has_command systemctl; then
    systemctl stop mo-anytls-sb >/dev/null 2>&1 || true
    systemctl disable mo-anytls-sb >/dev/null 2>&1 || true
    remove_file "$SYSTEMD_SERVICES_DIR/mo-anytls-sb.service"
    remove_file "$SYSTEMD_SERVICES_DIR/mo-anytls-sb@.service"
    systemctl daemon-reload
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -rf /etc/mo-anytls-sb "$SB_DIR"

  info "sing-box 已彻底从您的系统中移除！"
}

changeconf() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "配置文件不存在，请先安装 sing-box"
    return 1
  fi

  local old_pwd=$(jq -r '.inbounds[0].users[0].password' "$SB_CONFIG" 2>/dev/null || true)
  local old_cert=$(jq -r '.inbounds[0].tls.certificate_path' "$SB_CONFIG" 2>/dev/null || true)
  local old_key=$(jq -r '.inbounds[0].tls.key_path' "$SB_CONFIG" 2>/dev/null || true)
  local old_sni=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG" 2>/dev/null || "www.bing.com")

  clear
  echo -e "${GREEN}====== 修改 sing-box (AnyTLS) 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port 

  local auth_pwd
  # 这里的修改配置模块同样支持自定义新密码，回车则沿用旧密码
  read -rp "设置 AnyTLS 新密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local cert_path key_path sb_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    sb_domain="$old_sni"
  fi

  write_and_show_config
  info "配置修改并应用成功！"
}

showconf() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "未找到 AnyTLS 配置文件，请确保已成功部署节点。"
    return
  fi

  # 实时从服务端核心配置中提取参数，确保 100% 准确
  local hostname=$(hostname -s | sed 's/ /_/g')
  local main_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "18055")
  local auth_pwd=$(jq -r '.inbounds[0].users[0].password' "$SB_CONFIG" 2>/dev/null || echo "密码")
  local sb_domain=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG" 2>/dev/null || echo "anyoo.vfz.dpdns.org")
  
  # 自动判定证书校验逻辑：如果是 bing.com 的自签证书，则客户端必须 insecure=1；如果是合法 Acme 证书，则 insecure=0
  local is_insecure="0"
  local skip_cert="false"
  if [[ "$sb_domain" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

  local ip=$(get_public_ip)
  local url_ip="$ip"
  if [[ "$ip" =~ ":" ]]; then 
    url_ip="[$ip]"
  fi

  echo -e "${GREEN}====== AnyTLS 节点信息 ======${RESET}"
  echo -e "${YELLOW}IP      : ${ip}${RESET}"
  echo -e "${YELLOW}端口    : ${main_port}${RESET}"
  echo -e "${YELLOW}密码    : ${auth_pwd}${RESET}"
  echo -e "${YELLOW}SNI    : ${sb_domain}${RESET}"
  echo -e "${GREEN}---------------------------${RESET}"
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo -e "${GREEN}[信息] V2rayN 链接：${RESET}"
  echo -e "${YELLOW}anytls://${auth_pwd}@${url_ip}:${main_port}?security=tls&sni=${sb_domain}&insecure=${is_insecure}&allowInsecure=${is_insecure}&type=tcp&headerType=none#${hostname}-Anytls${RESET}"
  echo -e "${GREEN}[信息] Surge 配置：${RESET}"
  echo -e "${YELLOW}${hostname}-Anytls = anytls, ${url_ip}, ${main_port}, password=${auth_pwd}, sni=${sb_domain}, tfo=true, skip-cert-verify=${skip_cert}, reuse=false${RESET}"
  echo -e "${YELLOW}---------------------------------${RESET}"
  echo
}

# =========================================================
# 6. 面板主菜单循环
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_sb_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Sing-box AnyTLS 面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}2. 更新 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}3. 卸载 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box AnyTLS${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) instsingbox; pause ;;
      2) update_singbox; pause ;;
      3) unstsingbox; pause ;;
      4) changeconf; pause ;;
      5) 
        if has_command systemctl; then
          systemctl start mo-anytls-sb && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop mo-anytls-sb && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart mo-anytls-sb && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u mo-anytls-sb.service -n 50 --no-pager
        else
          warn "当前环境不支持 systemd 集中日志管理。"
        fi
        pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
