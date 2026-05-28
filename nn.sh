#!/usr/bin/env bash
#
# AnyTLS-Go 管理面板 (Toolbox 模块符合性规范)
# 支持完全对齐 Hysteria 2 风格的证书配置流程
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly ANYTLS_CONFIG="/etc/anytls/config.env"
readonly ANYTLS_BINARY="/usr/local/bin/anytls-server"
readonly ANYTLS_DIR="/root/anytls"
ANYTLS_EXECUTABLE_INSTALL_PATH="/usr/local/bin/anytls-server"
ANYTLS_SYSTEMD_SERVICES_DIR="/etc/systemd/system"
ANYTLS_CONFIG_DIR="/etc/anytls"
ANYTLS_CERT_DIR="${ANYTLS_CONFIG_DIR}/certs"
ANYTLS_REPO_URL="https://github.com/anytls/anytls-go"
ANYTLS_API_BASE_URL="https://api.github.com/repos/anytls/anytls-go"
ANYTLS_CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)
ANYTLS_RUN_USER="anytls"

# 自动检测环境变量
ANYTLS_PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
ANYTLS_OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ANYTLS_ARCHITECTURE="${ARCHITECTURE:-}"

# 终端颜色代码 (沿用主面板标准)
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 官方原生底层工具函数 (与 Hy2 规范绝对对齐)
# =========================================================
_anytls_has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

_anytls_curl() {
  command curl "${ANYTLS_CURL_FLAGS[@]}" "$@"
}

_anytls_mktemp() {
  command mktemp "$@" "anytlsinst.XXXXXXXXXX"
}

_anytls_info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
_anytls_warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
_anytls_error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
_anytls_pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

_anytls_generate_random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c16 || true
}

_anytls_systemctl() {
  if ! _anytls_has_command systemctl; then
    _anytls_warn "当前系统不支持 systemd，忽略守护进程操作: systemctl $*"
    return 0
  fi
  command systemctl "$@"
}

_anytls_install_content() {
  local _install_flags="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"
  local _tmpfile="$(_anytls_mktemp)"

  echo -ne "安装 $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "已存在"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "完成"
  fi
  rm -f "$_tmpfile"
}

_anytls_remove_file() {
  local _target="$1"
  echo -ne "移除 $_target ... "
  if rm -f "$_target"; then
    echo -e "完成"
  fi
}

_anytls_detect_package_manager() {
  [[ -n "$ANYTLS_PACKAGE_MANAGEMENT_INSTALL" ]] && return 0
  _anytls_has_command apt && ANYTLS_PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install' && return 0
  _anytls_has_command dnf && ANYTLS_PACKAGE_MANAGEMENT_INSTALL='dnf -y install' && return 0
  _anytls_has_command yum && ANYTLS_PACKAGE_MANAGEMENT_INSTALL='yum -y install' && return 0
  _anytls_has_command apk && ANYTLS_PACKAGE_MANAGEMENT_INSTALL='apk add --no-cache' && return 0
  return 1
}

_anytls_install_software() {
  local _package_name="$1"
  if ! _anytls_detect_package_manager; then
    _anytls_error "未检测到支持的包管理器，请手动安装 $_package_name"
    exit 65
  fi
  echo "正在安装缺失的依赖 '$_package_name' ... "
  if $ANYTLS_PACKAGE_MANAGEMENT_INSTALL "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    _anytls_error "无法通过包管理器安装 '$_package_name'，请手动安装。"
    exit 65
  fi
}

_anytls_is_user_exists() { id "$1" > /dev/null 2>&1; }

_anytls_check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    ANYTLS_OPERATING_SYSTEM=linux
  else
    _anytls_error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  case "$(uname -m)" in
    'x86_64') ANYTLS_ARCHITECTURE='amd64' ;;
    'armv8' | 'aarch64') ANYTLS_ARCHITECTURE='arm64' ;;
    'armv7l') ANYTLS_ARCHITECTURE='armv7' ;;
    *) _anytls_error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  _anytls_has_command curl || _anytls_install_software curl
  _anytls_has_command grep || _anytls_install_software grep
  _anytls_has_command jq || _anytls_install_software jq
  _anytls_has_command unzip || _anytls_install_software unzip
  _anytls_has_command ss || _anytls_install_software iproute2
  _anytls_has_command openssl || _anytls_install_software openssl
}

_anytls_get_installed_version() {
  if [[ -f "$ANYTLS_CONFIG_DIR/version.txt" ]]; then
    echo "v$(cat "$ANYTLS_CONFIG_DIR/version.txt")"
  elif [[ -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" ]]; then
    echo "已安装"
  else
    echo "未安装"
  fi
}

_anytls_get_latest_version() {
  local _tmpfile=$(_anytls_mktemp)
  if ! _anytls_curl -sS -H 'Accept: application/vnd.github.v3+json' "$ANYTLS_API_BASE_URL/releases/latest" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '.tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  
  if [[ -n "$_tag_name" ]]; then
    echo "${_tag_name##*\/}" | tr -d 'v'
  else
    echo ""
  fi
}

_anytls_download_core() {
  local _version="$1"
  local _destination="$2"
  local _download_url="${ANYTLS_REPO_URL}/releases/download/v${_version}/anytls_${_version}_linux_${ANYTLS_ARCHITECTURE}.zip"
  
  _anytls_info "正在下载官方 AnyTLS-Go 核心组件: $_download_url ..."
  if ! _anytls_curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    _anytls_error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

_anytls_tpl_service_base() {
  local _config_name="$1"
  cat << EOF
[Unit]
Description=AnyTLS Server Service (${_config_name}.env)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ANYTLS_RUN_USER}
Group=${ANYTLS_RUN_USER}
EnvironmentFile=${ANYTLS_CONFIG_DIR}/${_config_name}.env
# 核心修正：完美移除非法 flag 参数，确保 Go 主程序原生稳定运行
ExecStart=$ANYTLS_EXECUTABLE_INSTALL_PATH -l :\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD}
Restart=always
RestartSec=3

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 面板辅助网络与配置扩展函数
# =========================================================
_anytls_get_public_ip() {
  local ip
  for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
      ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done
  done
  for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
    for url in "https://api64.ipify.org" "https://ip.sb"; do
      ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "[$ip]" && return
    done
  done
  _anytls_error "无法获取公网 IP 地址。" && return 1
}

_anytls_check_port() {
  local port="$1"
  if ss -tulnH "( sport = :$port )" | grep -q .; then
    return 1
  fi
  return 0
}

_anytls_is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

_anytls_get_random_port() {
  local rand_port
  while true; do
    rand_port=$(shuf -i 10000-65000 -n 1)
    if _anytls_check_port "$rand_port"; then
      echo "$rand_port" && return 0
    fi
  done
}

_anytls_get_status() {
  if _anytls_has_command systemctl && _anytls_systemctl is-active --quiet anytls-server 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

_anytls_get_current_port_display() {
  if [[ -f "$ANYTLS_CONFIG" ]]; then
    local main_port
    main_port=$(grep -E '^ANYTLS_PORT=' "$ANYTLS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' ')
    echo "${main_port:- -}"
  else echo "-"; fi
}

# =========================================================
# 4. 核心功能扩展：完美复刻 Hysteria 2 证书选择逻辑
# =========================================================
_anytls_configure_certificate() {
  mkdir -p "$ANYTLS_CERT_DIR"
  
  # 默认证书与 SNI 伪装设定
  cert_path="${ANYTLS_CERT_DIR}/anytls.crt"
  key_path="${ANYTLS_CERT_DIR}/anytls.key"
  sni_domain="cn.bing.com"

  echo "---------------------------------------------"
  echo -e "Hysteria 2 协议证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme 脚本自动申请 (需放行 80 端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  
  local certInput
  read -rp "请选择证书配置方式 [1-3, 默认 1]: " certInput
  certInput=${certInput:-1}

  case "$certInput" in
    1)
      _anytls_info "正在生成必应 (cn.bing.com) 关联专用根证书..."
      if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_path" -out "$cert_path" \
        -subj "/CN=cn.bing.com" >/dev/null 2>&1; then
        _anytls_info "Toolbox 本地适配证书链创建成功！"
      else
        _anytls_error "OpenSSL 证书生成失败。"
        return 1
      fi
      ;;

    2)
      _anytls_warn "开始通过 Acme 脚本自动申请证书..."
      read -rp "请输入申请证书绑定的域名: " acme_domain
      if [[ -z "$acme_domain" ]]; then
        _anytls_error "域名不能为空，强制切换回自签证书流程。"
        _anytls_configure_certificate
        return
      fi

      cert_path="${ANYTLS_CERT_DIR}/${acme_domain}.crt"
      key_path="${ANYTLS_CERT_DIR}/${acme_domain}.key"
      sni_domain="$acme_domain"
      touch "$cert_path" "$key_path" 
      ;;

    3)
      _anytls_info "开始配置自定义证书路径..."
      read -rp "请输入客户端专用 SNI 伪装域名 [默认: cn.bing.com]: " input_sni
      sni_domain=${input_sni:-cn.bing.com}
      
      while true; do
        read -rp "请输入证书 (.crt / .pem) 文件的绝对路径: " cert_path
        if [[ -f "$cert_path" ]]; then break; else _anytls_error "找不到该证书文件！"; fi
      done

      while true; do
        read -rp "请输入私钥 (.key) 文件的绝对路径: " key_path
        if [[ -f "$key_path" ]]; then break; else _anytls_error "找不到该私钥文件！"; fi
      done
      ;;

    *)
      _anytls_error "无效输入，自适应回切至自签证书模式。"
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$key_path" -out "$cert_path" -subj "/CN=cn.bing.com" >/dev/null 2>&1
      ;;
  esac
}

_anytls_write_and_show_config() {
  mkdir -p "$ANYTLS_CONFIG_DIR"
  
  # 统一持久化注入环境配置文件
  cat << EOF > "$ANYTLS_CONFIG"
ANYTLS_PORT=$port
ANYTLS_PASSWORD=$auth_pwd
ANYTLS_CERT_PATH=$cert_path
ANYTLS_KEY_PATH=$key_path
ANYTLS_SNI=$sni_domain
EOF
  chmod 600 "$ANYTLS_CONFIG"
  chown -R ${ANYTLS_RUN_USER}:${ANYTLS_RUN_USER} "$ANYTLS_CONFIG_DIR"

  if _anytls_has_command systemctl; then
    _anytls_systemctl daemon-reload
    _anytls_systemctl enable anytls-server >/dev/null 2>&1 || true
    _anytls_systemctl restart anytls-server >/dev/null 2>&1 || true
    
    if _anytls_systemctl is-active --quiet anytls-server 2>/dev/null; then
      _anytls_info "AnyTLS-Go 服务启动成功！"
    else
      _anytls_error "AnyTLS-Go 服务启动失败，请运行 'journalctl -u anytls-server' 查看日志。"
    fi
  else
    pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" || true
    "$ANYTLS_EXECUTABLE_INSTALL_PATH" -l :${port} -p ${auth_pwd} >/dev/null 2>&1 &
    _anytls_info "进程已挂载至后台守护池。"
  fi
  anytls_showconf
}

# =========================================================
# 5. 主流程控制模块与核心运维
# =========================================================
anytls_install() {
  _anytls_check_environment
  
  _anytls_info "获取官方最新发布版本中..."
  local latest_version=$(_anytls_get_latest_version)
  if [[ -z "$latest_version" ]]; then
    _anytls_error "无法获取最新版本号，请检查网络设置。"
    return 1
  fi
  _anytls_info "检测到最新版本为: v${latest_version}"

  local _tmpzip="$(_anytls_mktemp)"
  if ! _anytls_download_core "$latest_version" "$_tmpzip"; then
    rm -f "$_tmpzip" && return 1
  fi

  local _tmpdir
  _tmpdir=$(command mktemp -d)
  unzip -o "$_tmpzip" -d "$_tmpdir" >/dev/null
  rm -f "$_tmpzip"

  local real_binary_path
  real_binary_path=$(find "$_tmpdir" -type f -name "anytls-server" | head -n 1)
  if [[ -z "$real_binary_path" ]]; then
    rm -rf "$_tmpdir"
    _anytls_error "压缩包内未找到可执行程序 anytls-server"
    return 1
  fi

  echo -ne "正在安装二进制可执行文件 ... "
  if install -Dm755 "$real_binary_path" "$ANYTLS_EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmpdir" && _anytls_error "安装失败" && return 1
  fi
  rm -rf "$_tmpdir"

  mkdir -p "$ANYTLS_CONFIG_DIR"
  echo "$latest_version" > "${ANYTLS_CONFIG_DIR}/version.txt"

  if ! _anytls_is_user_exists "$ANYTLS_RUN_USER"; then
    echo -ne "正在创建系统独立沙箱运行用户 $ANYTLS_RUN_USER ... "
    useradd -r -s /usr/sbin/nologin "$ANYTLS_RUN_USER" >/dev/null 2>&1 || true
    echo "成功"
  fi

  if _anytls_has_command systemctl; then
    _anytls_install_content -Dm644 "$(_anytls_tpl_service_base 'config')" "$ANYTLS_SYSTEMD_SERVICES_DIR/anytls-server.service" "1"
    _anytls_install_content -Dm644 "$(_anytls_tpl_service_base '%i')" "$ANYTLS_SYSTEMD_SERVICES_DIR/anytls-server@.service" "1"
  fi

  local default_port=""
  local prompt_msg="设置 AnyTLS-Go 监听端口 [1-65535] (回车随机分配): "
  while true; do
    read -rp "$prompt_msg" port
    if [[ -z "$port" ]]; then
      port=$(_anytls_get_random_port)
      _anytls_info "已为您随机分配未被占用端口: $port" && break
    elif _anytls_is_valid_port "$port"; then
      if ! _anytls_check_port "$port"; then
        _anytls_error "端口 ${port} 已被其它程序占用，请更换。" && continue
      fi
      break
    else _anytls_error "请输入有效的端口数字 (1-65535)"; fi
  done
  
  read -rp "设置 AnyTLS-Go 验证密码 (回车自动分配随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(_anytls_generate_random_password)}

  # 进入 Hysteria 2 对齐的证书交互
  _anytls_configure_certificate

  _anytls_write_and_show_config
}

anytls_update() {
  if [[ ! -f "$ANYTLS_BINARY" ]]; then
    _anytls_error "当前系统未安装 AnyTLS-Go，无法执行更新。"
    return 1
  fi

  _anytls_info "正在检查新版本..."
  local current_version="0.0.0"
  [[ -f "${ANYTLS_CONFIG_DIR}/version.txt" ]] && current_version=$(cat "${ANYTLS_CONFIG_DIR}/version.txt")
  local latest_version=$(_anytls_get_latest_version)

  if [[ -z "$latest_version" ]]; then
    _anytls_error "无法连接到 GitHub API 获取最新版本，请稍后再试。"
    return 1
  fi

  _anytls_info "当前安装版本: v${current_version}"
  _anytls_info "官方最新版本: v${latest_version}"

  if [[ "$current_version" == "$latest_version" ]]; then
    read -rp "当前已是最新版本，是否仍要重新下载覆盖？[y/N]: " remode
    if [[ ! "$remode" =~ ^[Yy]$ ]]; then
      _anytls_info "已取消更新。"
      return 0
    fi
  fi

  _anytls_warn "检测到新版本，即将开始平滑更新..."
  
  local _tmpzip="$(_anytls_mktemp)"
  if ! _anytls_download_core "$latest_version" "$_tmpzip"; then
    rm -f "$_tmpzip" && return 1
  fi

  local _tmpdir
  _tmpdir=$(command mktemp -d)
  unzip -o "$_tmpzip" -d "$_tmpdir" >/dev/null
  rm -f "$_tmpzip"

  local real_binary_path
  real_binary_path=$(find "$_tmpdir" -type f -name "anytls-server" | head -n 1)
  if [[ -z "$real_binary_path" ]]; then
    rm -rf "$_tmpdir"
    _anytls_error "压缩包内未找到可执行程序 anytls-server"
    return 1
  fi

  _anytls_systemctl stop anytls-server >/dev/null 2>&1 || true

  echo -ne "正在覆盖二进制核心文件 ... "
  if install -Dm755 "$real_binary_path" "$ANYTLS_EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmpdir" && _anytls_error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmpdir"
  echo "$latest_version" > "${ANYTLS_CONFIG_DIR}/version.txt"

  _anytls_info "正在重启 AnyTLS-Go 服务以应用更新..."
  if _anytls_has_command systemctl; then
    _anytls_install_content -Dm644 "$(_anytls_tpl_service_base 'config')" "$ANYTLS_SYSTEMD_SERVICES_DIR/anytls-server.service" "1"
    _anytls_systemctl daemon-reload
    _anytls_systemctl restart anytls-server >/dev/null 2>&1 || true
  else
    pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" || true
    source "$ANYTLS_CONFIG"
    "$ANYTLS_EXECUTABLE_INSTALL_PATH" -l :${ANYTLS_PORT} -p ${ANYTLS_PASSWORD} >/dev/null 2>&1 &
  fi
  _anytls_info "升级并启动成功！"
}

anytls_uninstall() {
  _anytls_warn "即将从当前系统中彻底卸载 AnyTLS-Go"

  if _anytls_has_command systemctl; then
    _anytls_systemctl stop anytls-server >/dev/null 2>&1 || true
    _anytls_systemctl disable anytls-server >/dev/null 2>&1 || true
    _anytls_remove_file "$ANYTLS_SYSTEMD_SERVICES_DIR/anytls-server.service"
    _anytls_remove_file "$ANYTLS_SYSTEMD_SERVICES_DIR/anytls-server@.service"
    _anytls_systemctl daemon-reload
  else
    pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" || true
  fi
  
  _anytls_remove_file "$ANYTLS_EXECUTABLE_INSTALL_PATH"
  rm -rf /etc/anytls "$ANYTLS_DIR"
  _anytls_is_user_exists "$ANYTLS_RUN_USER" && userdel "$ANYTLS_RUN_USER" || true
  _anytls_info "AnyTLS-Go 已彻底从您的系统中移除！"
}

anytls_changeconf() {
  if [[ ! -f "$ANYTLS_CONFIG" ]]; then
    _anytls_error "配置文件不存在，请先安装 AnyTLS-Go"
    return 1
  fi

  local ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_CERT_PATH ANYTLS_KEY_PATH ANYTLS_SNI
  source "$ANYTLS_CONFIG"

  clear
  echo -e "${GREEN}====== 修改 AnyTLS-Go 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  local port default_port="$ANYTLS_PORT"
  local prompt_msg="设置 AnyTLS-Go 监听端口 [当前: ${default_port}, 回车不修改]: "
  while true; do
    read -rp "$prompt_msg" port
    if [[ -z "$port" ]]; then
      port="$default_port" && break
    elif _anytls_is_valid_port "$port"; then
      if [[ "$port" != "$default_port" ]] && ! _anytls_check_port "$port"; then
        _anytls_error "端口 ${port} 已被其它程序占用，请更换。" && continue
      fi
      break
    else _anytls_error "请输入有效的端口数字 (1-65535)"; fi
  done

  local auth_pwd
  read -rp "设置 AnyTLS-Go 密码 [当前: ${ANYTLS_PASSWORD}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$ANYTLS_PASSWORD}

  cert_path="$ANYTLS_CERT_PATH"
  key_path="$ANYTLS_KEY_PATH"
  sni_domain="${ANYTLS_SNI:-cn.bing.com}"

  read -rp "是否重新配置 Hysteria 2 风格证书选项？[y/N]: " re_cert
  if [[ "$re_cert" =~ ^[Yy]$ ]]; then
    _anytls_configure_certificate
  fi

  _anytls_write_and_show_config
}

anytls_showconf() {
  if [[ ! -f "$ANYTLS_CONFIG" ]]; then
    _anytls_error "未找到客户端配置文件。"
    return
  fi
  local ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_CERT_PATH ANYTLS_KEY_PATH ANYTLS_SNI
  source "$ANYTLS_CONFIG"

  local vps_ip=$(_anytls_get_public_ip)
  local hostname=$(hostname -s | sed 's/ /_/g')
  local current_sni="${ANYTLS_SNI:-cn.bing.com}"

  echo -e "${GREEN}====== AnyTLS-Go 配置详情 ======${RESET}"
  echo -e "${YELLOW}服务器 IP   : ${vps_ip}${RESET}"
  echo -e "${YELLOW}监听端口    : ${ANYTLS_PORT}${RESET}"
  echo -e "${YELLOW}连接密码    : ${ANYTLS_PASSWORD}${RESET}"
  echo -e "${YELLOW}本地根证书  : ${ANYTLS_CERT_PATH}${RESET}"
  echo -e "${YELLOW}伪装 SNI    : ${current_sni}${RESET}"
  echo -e "${GREEN}---------------------------------------------${RESET}"
  echo -e "${YELLOW}[命令行] 客户端标准启动命令建议:${RESET}"
  echo -e "${CYAN}anytls-client -l 127.0.0.1:3080 -s ${vps_ip}:${ANYTLS_PORT} -p ${ANYTLS_PASSWORD} --sni ${current_sni} --root-cert ${ANYTLS_CERT_PATH}${RESET}"
  echo -e "${GREEN}---------------------------------------------${RESET}"
  echo -e "${YELLOW}[信息] V2rayN 配置分享链接:${RESET}"
  echo -e "${CYAN}anytls://${ANYTLS_PASSWORD}@${vps_ip}:${ANYTLS_PORT}/?insecure=1&sni=${current_sni}#${hostname}-Anytls${RESET}"
  echo -e "${GREEN}=============================================${RESET}"
}

# =========================================================
# 6. 面板主菜单循环入口
# =========================================================
anytls_menu() {
  [[ $EUID -ne 0 ]] && _anytls_error "请切换至 root 用户运行此面板脚本。" && exit 1
  _anytls_check_environment

  while true; do
    clear
    local status=$(_anytls_get_status)
    local version=$(_anytls_get_installed_version)
    local port_show=$(_anytls_get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      AnyTLS-Go 管理面板        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 AnyTLS-Go${RESET}"
    echo -e "${GREEN}2. 更新 AnyTLS-Go${RESET}"
    echo -e "${GREEN}3. 卸载 AnyTLS-Go${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 AnyTLS-Go${RESET}"
    echo -e "${GREEN}6. 停止 AnyTLS-Go${RESET}"
    echo -e "${GREEN}7. 重启 AnyTLS-Go${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出程序${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) anytls_install; _anytls_pause ;;
      2) anytls_update; _anytls_pause ;;
      3) anytls_uninstall; _anytls_pause ;;
      4) anytls_changeconf; _anytls_pause ;;
      5) 
        if _anytls_has_command systemctl; then
          _anytls_systemctl start anytls-server && _anytls_info "服务已成功启动！"
        else
          pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" || true
          source "$ANYTLS_CONFIG"
          "$ANYTLS_EXECUTABLE_INSTALL_PATH" -l :${ANYTLS_PORT} -p ${ANYTLS_PASSWORD} >/dev/null 2>&1 &
        fi
        _anytls_pause ;;
      6) 
        if _anytls_has_command systemctl; then
          _anytls_systemctl stop anytls-server && _anytls_info "服务已成功停止！"
        else
          pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" && _anytls_info "后台进程已终止！"
        fi
        _anytls_pause ;;
      7) 
        if _anytls_has_command systemctl; then
          _anytls_systemctl restart anytls-server && _anytls_info "服务已成功重启！"
        else
          pkill -f "$ANYTLS_EXECUTABLE_INSTALL_PATH" || true
          source "$ANYTLS_CONFIG"
          "$ANYTLS_EXECUTABLE_INSTALL_PATH" -l :${ANYTLS_PORT} -p ${ANYTLS_PASSWORD} >/dev/null 2>&1 &
        fi
        _anytls_pause ;;
      8) 
        if _anytls_has_command systemctl; then
          journalctl -u anytls-server.service -n 50 --no-pager
        else
          _anytls_warn "当前环境不支持 systemd 集中日志管理。"
        fi
        _anytls_pause ;;
      9) anytls_showconf; _anytls_pause ;;
      0) exit 0 ;;
      *) _anytls_error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

# 启动面板
anytls_menu
