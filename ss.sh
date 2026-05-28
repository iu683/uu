#!/usr/bin/env bash
#
# Sing-box (AnyTLS + Reality) 核心控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly SB_CONFIG="/etc/sing-box/config.json"
readonly SB_BINARY="/usr/local/bin/sing-box"
readonly SB_DIR="/root/sb_node"
readonly STATE_FILE="/etc/anyreality-singbox.env"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/sing-box"
REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境与动态变量池
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"

# 终端规范颜色代码
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
  command mktemp "$@" "sbservinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

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

check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  case "$(uname -m)" in
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command tar || install_software tar
  has_command python3 || install_software python3
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1 || echo "未知格式"
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
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '[.[] | select(.prerelease==false and .draft==false)][0].tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  
  if [[ -n "$_tag_name" ]]; then
    echo "${_tag_name##*\/}"
  else
    echo "v1.12.3"
  fi
}

download_singbox() {
  local _version="$1"
  local _destination="$2"
  local _ver_num="${_version#v}"
  
  local _download_url="$REPO_URL/releases/download/$_version/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE.tar.gz"
  
  info "正在自 GitHub 下载官方 Sing-box 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "从 GitHub 下载核心失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

get_public_ip() {
  local ip=''
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip=$(curl -4s --max-time 5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  hostname -I | awk '{print $1}'
}

tpl_singbox_server_service_base() {
  cat << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$EXECUTABLE_INSTALL_PATH run -c $SB_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 面板辅助网络与状态扩展函数
# =========================================================
get_sb_status() {
  if has_command systemctl && systemctl is-active --quiet sing-box 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$SB_CONFIG" ]]; then
    local port
    port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "")
    echo "${port:- -}"
  else echo "-"; fi
}

generate_or_use_key() {
  if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
    return
  fi
  local key_out
  key_out=$("$EXECUTABLE_INSTALL_PATH" generate reality-keypair 2>/dev/null || echo "")
  PRIVATE_KEY=$(awk '/PrivateKey/ {print $2}' <<< "$key_out")
  PUBLIC_KEY=$(awk '/PublicKey/ {print $2}' <<< "$key_out")
}

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
  mkdir -p "$CONFIG_DIR"

  cat << EOF > "$SB_CONFIG"
{
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${USERNAME}",
          "password": "${PASSWORD}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": "${SHORT_ID}"
        }
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

  SERVER_IP=$(get_public_ip)
  cat << EOF > "$STATE_FILE"
PORT='${PORT}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
SERVER_NAME='${SERVER_NAME}'
SHORT_ID='${SHORT_ID}'
REMARK='${REMARK}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SERVER_IP='${SERVER_IP}'
EOF
  chmod 600 "$STATE_FILE"

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      info "Sing-box (AnyTLS) 服务配置并启动成功！"
    else
      error "Sing-box 服务启动失败，请运行 'journalctl -u sing-box -f' 查看错误日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "非 systemd 环境，程序已挂载至后台 Pid 进程池中运行。"
  fi
  
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi

  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================

# 流程一：纯净首次安装
inst_singbox() {
  check_environment
  
  if [[ -f "$SB_CONFIG" ]]; then
    warn "系统检测到已存在配置。如果是要修改配置，请在菜单中选择选项 4。"
    read -rp "是否执意重新安装？(旧配置将被覆盖) [y/N]: " CONFIRM_REINST
    [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
  fi

  info "🧹 正在清理前置依赖并准备下载..."
  if ! command -v sing-box >/dev/null 2>&1; then
    info "获取 GitHub 官方最新发布版本中..."
    local latest_version=$(get_latest_version)
    
    local _tmpfile_tar=$(mktemp)
    if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
      rm -f "$_tmpfile_tar" && return 1
    fi

    echo -ne "正在从解压并安装二进制可执行文件 ... "
    local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
    tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
    
    local _ver_num="${latest_version#v}"
    if install -Dm755 "$_tmpdir_extract/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE/sing-box" "$EXECUTABLE_INSTALL_PATH"; then
      echo "成功"
    else
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "安装失败" && return 1
    fi
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract"
  else
    info "系统已存在 sing-box 核心组件，跳过基础安装。"
  fi

  if has_command systemctl && [[ ! -f "$SYSTEMD_SERVICES_DIR/sing-box.service" ]]; then
    install_content -Dm644 "$(tpl_singbox_server_service_base)" "$SYSTEMD_SERVICES_DIR/sing-box.service" "1"
  fi

  # 全新随机默认值
  local rand_port=$(shuf -i 10000-65535 -n 1)
  local rand_user=$(python3 -c "import secrets, string; print('user-' + ''.join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))")
  local rand_pass=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12)))")
  local rand_sid=$(python3 -c "import secrets; print(secrets.token_hex(8))")

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$rand_port}

  read -rp "👉 请输入用户名 (默认随机: ${rand_user}): " INPUT_USERNAME
  USERNAME=${INPUT_USERNAME:-$rand_user}

  read -rp "👉 请输入密码 (默认随机: ${rand_pass}): " INPUT_PASSWORD
  PASSWORD=${INPUT_PASSWORD:-$rand_pass}

  read -rp "👉 请输入伪装域名/SNI (默认: www.amazon.com): " INPUT_SERVER_NAME
  SERVER_NAME=${INPUT_SERVER_NAME:-www.amazon.com}

  read -rp "👉 请输入 Reality short_id (默认随机: ${rand_sid}): " INPUT_SHORT_ID
  SHORT_ID=${INPUT_SHORT_ID:-$rand_sid}

  read -rp "👉 请输入节点备注名称 (默认: AnyReality): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-AnyReality}

  PRIVATE_KEY=""
  PUBLIC_KEY=""
  generate_or_use_key
  write_and_show_config
}

# 流程二：修改已有配置（核心重构部分：回车保持不变）
modify_config() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "未找到正在运行的配置文件，请先选择选项 1 安装节点。"
    return 1
  fi

  info "正在读取现有节点配置..."
  # 优先从标准 JSON 配置文件使用 jq 精准提炼
  local current_port=$(jq -r '.inbounds[0].listen_port // empty' "$SB_CONFIG" 2>/dev/null)
  local current_user=$(jq -r '.inbounds[0].users[0].name // empty' "$SB_CONFIG" 2>/dev/null)
  local current_pass=$(jq -r '.inbounds[0].users[0].password // empty' "$SB_CONFIG" 2>/dev/null)
  local current_sni=$(jq -r '.inbounds[0].tls.server_name // empty' "$SB_CONFIG" 2>/dev/null)
  local current_sid=$(jq -r '.inbounds[0].tls.reality.short_id // empty' "$SB_CONFIG" 2>/dev/null)
  
  # 密钥及备注辅助读取
  local current_private_key=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_CONFIG" 2>/dev/null)
  local current_remark=""
  local current_public_key=""
  if [[ -f "$STATE_FILE" ]]; then
    current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
    current_public_key=$(grep -E "^PUBLIC_KEY=" "$STATE_FILE" | cut -d"'" -f2 || true)
  fi

  echo "---------------------------------------------"
  echo -e "${YELLOW}提示：直接敲回车(Enter)将保持括号内的当前值不变${RESET}"
  echo "---------------------------------------------"

  read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$current_port}

  read -rp "👉 修改用户名 (当前: ${current_user}): " INPUT_USERNAME
  USERNAME=${INPUT_USERNAME:-$current_user}

  read -rp "👉 修改密码 (当前: ${current_pass}): " INPUT_PASSWORD
  PASSWORD=${INPUT_PASSWORD:-$current_pass}

  read -rp "👉 修改伪装域名/SNI (当前: ${current_sni}): " INPUT_SERVER_NAME
  SERVER_NAME=${INPUT_SERVER_NAME:-$current_sni}

  read -rp "👉 修改 Reality short_id (当前: ${current_sid}): " INPUT_SHORT_ID
  SHORT_ID=${INPUT_SHORT_ID:-$current_sid}

  read -rp "👉 修改节点备注名称 (当前: ${current_remark:-anytls-reality-tls}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-${current_remark:-anytls-reality-tls}}

  # 继承原有密钥
  PRIVATE_KEY="$current_private_key"
  PUBLIC_KEY="$current_public_key"

  generate_or_use_key
  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$SB_BINARY" ]]; then
    error "当前系统未安装 Sing-box，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local latest_version=$(get_latest_version)

  info "当前安装版本: ${YELLOW}${current_version}${RESET}"
  info "官方最新版本: ${GREEN}${latest_version}${RESET}"

  if [[ "$current_version" == *"$latest_version"* || "$latest_version" == *"$current_version"* ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "检测到新版本，即将开始平滑更新 (你的节点配置不会改变)..."
  
  local _tmpfile_tar=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
    rm -f "$_tmpfile_tar" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
  tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
  
  local _ver_num="${latest_version#v}"
  if install -Dm755 "$_tmpdir_extract/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE/sing-box" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  info "正在重启 Sing-box 服务以应用更新..."
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl restart sing-box >/dev/null 2>&1 || true
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      info "Sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但服务重启失败，请运行 'journalctl -u sing-box -f' 检查错误。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "Sing-box 核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  if has_command systemctl; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    remove_file "$SYSTEMD_SERVICES_DIR/sing-box.service"
    systemctl daemon-reload
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -f "$SB_CONFIG" "$STATE_FILE"
  rm -rf "$CONFIG_DIR" "$SB_DIR"

  info "已卸载 Sing-box、配置文件与状态文件。"
}

showconf() {
  if [[ ! -f "$STATE_FILE" ]]; then
    error "未找到任何安装配置底座，请先安装节点。"
    return 1
  fi
  source "$STATE_FILE"

  local encoded_remark=$(jq -rn --arg x "$REMARK" '$x|@uri')
  local v2rayn_link="anytls://${PASSWORD}@${SERVER_IP}:${PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${encoded_remark}"

  echo -e "${GREEN}====== AnyTLS+Reality 节点配置信息 ======${RESET}"
  echo -e "${GREEN}服务器公网 IP :${RESET} ${SERVER_IP}"
  echo -e "${GREEN}服务监听端口   :${RESET} ${PORT}"
  echo -e "${GREEN}认证用户名     :${RESET} ${USERNAME}"
  echo -e "${GREEN}认证通信密码   :${RESET} ${PASSWORD}"
  echo -e "${GREEN}伪装域名 (SNI) :${RESET} ${SERVER_NAME}"
  echo -e "${GREEN}Reality 公钥   :${RESET} ${PUBLIC_KEY}"
  echo -e "${GREEN}Reality 目标ID :${RESET} ${SHORT_ID}"
  echo -e "${GREEN}客户端指纹模式 :${RESET} chrome"
  echo -e "${GREEN}节点自定义备注 :${RESET} ${REMARK}"
  echo "---------------------------------------------"
  echo -e "${GREEN}👉 v2rayN 分享链接:${RESET}"
  echo -e "${YELLOW}${v2rayn_link}${RESET}"
  echo "---------------------------------------------"
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
    local status=$(get_sb_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} Sing-box AnyTLS + Reality 面板  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 AnyReality${RESET}"
    echo -e "${GREEN}2. 更新 AnyReality${RESET}"
    echo -e "${GREEN}3. 卸载 AnyReality${RESET}"
    echo -e "${GREEN}4. 修改已有配置${RESET}"
    echo -e "${GREEN}5. 启动 AnyReality${RESET}"
    echo -e "${GREEN}6. 停止 AnyReality${RESET}"
    echo -e "${GREEN}7. 重启 AnyReality${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_singbox; pause ;;
      2) update_singbox; pause ;;
      3) uninstall_singbox; pause ;;
      4) modify_config; pause ;;
      5) 
        if has_command systemctl; then
          systemctl start sing-box && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop sing-box && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart sing-box && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u sing-box.service -n 50 --no-pager
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
