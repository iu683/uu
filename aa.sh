#!/usr/bin/env bash
#
# Sing-box (AnyTLS + Reality) Alpine 专属核心控制面板 (独立共存版)
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 【重构：独立路径与服务名，防止与原生冲突】
readonly SB_SERVICE_NAME="sing-box-anyreality"
readonly SB_CONFIG="/etc/sing-box-anyreality/config.json"
readonly SB_BINARY="/usr/local/bin/sing-box-anyreality"
readonly SB_DIR="/root/AnyReality"
readonly STATE_FILE="/etc/anyreality-singbox-standalone.env"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box-anyreality"
INIT_SERVICE_DIR="/etc/init.d"
CONFIG_DIR="/etc/sing-box-anyreality"

REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境与动态变量池
OPERATING_SYSTEM="linux"
ARCHITECTURE=""

# 终端规范颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. Alpine 原生底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp -t "sbservinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# OpenRC 服务状态与操作封装
rc_service() {
  if ! has_command rc-service; then
    return 1
  fi
  command rc-service "$@"
}

rc_update() {
  if ! has_command rc-update; then
    return 1
  fi
  command rc-update "$@"
}

install_content() {
  local _perms="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"

  echo -ne "安装 $_destination ... "
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "已存在"
  else
    # 深度兼容级联创建，防止精简版环境报错
    if mkdir -p "$(dirname "$_destination")" && echo "$_content" > "$_destination" && chmod "$_perms" "$_destination"; then
      echo -e "完成"
    else
      echo -e "失败"
    fi
  fi
}

remove_file() {
  local _target="$1"
  echo -ne "移除 $_target ... "
  if rm -f "$_target"; then
    echo -e "完成"
  fi
}

install_software() {
  local _package_name="$1"
  echo "正在通过 apk 安装缺失的依赖 '$_package_name' ... "
  if apk add --no-cache "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    error "无法通过 apk 安装 '$_package_name'，请手动检查 Alpine 源配置。"
    exit 65
  fi
}

check_environment() {
  if [[ ! -f /etc/alpine-release ]]; then
    warn "检测到当前系统可能不是 Alpine Linux，但脚本将继续尝试运行..."
  fi

  case "$(uname -m)" in
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  # 确保 Alpine 环境具备基本依赖
  has_command bash || install_software bash
  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command tar || install_software tar
  has_command python3 || install_software python3
  has_command openssl || install_software openssl
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
    echo "v1.12.3"
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
  hostname -i | awk '{print $1}' 2>/dev/null || echo "127.0.0.1"
}

# Alpine OpenRC 专属服务脚本底座（已独立化重构）
tpl_singbox_server_openrc_base() {
  cat << EOF
#!/sbin/openrc-run

description="Sing-box AnyTLS Reality Standalone Service"
supervisor="supervise-daemon"
command="${EXECUTABLE_INSTALL_PATH}"
command_args="run -c ${SB_CONFIG}"
extra_started_commands="reload"

depend() {
    need net
    after firewall
}

reload() {
    ebegin "Reloading ${SB_SERVICE_NAME} configuration"
    supervise-daemon --signal HUP --name ${SB_SERVICE_NAME}
    eend \$?
}
EOF
}

# =========================================================
# 3. 面板辅助网络与状态扩展函数
# =========================================================
get_sb_status() {
  if has_command rc-service && rc-service "$SB_SERVICE_NAME" status >/dev/null 2>&1; then
    echo -e "${GREEN}● 运行中 ${RESET}"
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

  # 托管环境行为控制
  if has_command rc-service && [ -d "$INIT_SERVICE_DIR" ]; then
    rc_update add "$SB_SERVICE_NAME" default >/dev/null 2>&1 || true
    rc_service "$SB_SERVICE_NAME" restart >/dev/null 2>&1 || true
    if rc_service "$SB_SERVICE_NAME" status >/dev/null 2>&1; then
      info "Sing-box (AnyTLS) 独立服务通过 OpenRC 启动成功！"
    else
      error "Sing-box 独立服务启动失败，请检查 /var/log/messages 日志。"
    fi
  else
    # 极简无 OpenRC 容器降级策略
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "未检测到 OpenRC 环境，独立程序已挂载至后台常驻进程模式。"
  fi
  
  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================

inst_singbox() {
  check_environment
  
  if [[ -f "$SB_CONFIG" ]]; then
    warn "系统检测到已存在独立配置。如果是要修改配置，请在菜单中选择选项 4。"
    read -rp "是否执意重新安装？(旧配置将被覆盖) [y/N]: " CONFIRM_REINST
    [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
  fi

  info "🧹 正在清理前置依赖并准备下载..."
  if [[ ! -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local latest_version=$(get_latest_version)
    
    local _tmpfile_tar=$(mktemp)
    if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
      rm -f "$_tmpfile_tar" && return 1
    fi

    echo -ne "正在解压并安装独立二进制可执行文件 ... "
    local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
    tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
    
    local _ver_num="${latest_version#v}"
    local _extracted_binary=$(find "$_tmpdir_extract" -type f -name "sing-box" | head -n 1)

    if [[ -n "$_extracted_binary" ]]; then
      mkdir -p "$(dirname "$EXECUTABLE_INSTALL_PATH")"
      if cp "$_extracted_binary" "$EXECUTABLE_INSTALL_PATH" && chmod 755 "$EXECUTABLE_INSTALL_PATH"; then
        echo "成功"
      else
        rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "安装失败" && return 1
      fi
    else
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "找不到解压核心" && return 1
    fi
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract"
  else
    info "系统已存在该独立版本的核心组件，跳过基础安装。"
  fi

  # 写入服务脚本（采用完全兼容 BusyBox 的 install_content 原生重构版）
  install_content "0755" "$(tpl_singbox_server_openrc_base)" "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" "1"

  # 兼容 Alpine 无 shuf 的随机数处理机制
  local rand_port=$(awk 'BEGIN{srand();print int(rand()*(65535-10000+1))+10000}')
  local rand_user=$(python3 -c "import secrets, string; print('user-' + ''.join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))")
  local rand_pass=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12)))")
  local rand_sid=$(python3 -c "import secrets; print(secrets.token_hex(8))")
  local hostname_str=$(hostname 2>/dev/null || echo "alpine")
  local default_remark="${hostname_str}-AnyReality"

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

  read -rp "👉 请输入节点备注名称 (默认: ${default_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-$default_remark}

  PRIVATE_KEY=""
  PUBLIC_KEY=""
  generate_or_use_key
  write_and_show_config
}

modify_config() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "未找到正在运行的配置文件，请先选择选项 1 安装节点。"
    return 1
  fi

  info "正在读取现有节点配置..."
  local current_port=$(jq -r '.inbounds[0].listen_port // empty' "$SB_CONFIG" 2>/dev/null)
  local current_user=$(jq -r '.inbounds[0].users[0].name // empty' "$SB_CONFIG" 2>/dev/null)
  local current_pass=$(jq -r '.inbounds[0].users[0].password // empty' "$SB_CONFIG" 2>/dev/null)
  local current_sni=$(jq -r '.inbounds[0].tls.server_name // empty' "$SB_CONFIG" 2>/dev/null)
  local current_sid=$(jq -r '.inbounds[0].tls.reality.short_id // empty' "$SB_CONFIG" 2>/dev/null)
  
  local current_private_key=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_CONFIG" 2>/dev/null)
  local current_remark=""
  local current_public_key=""
  if [[ -f "$STATE_FILE" ]]; then
    current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
    current_public_key=$(grep -E "^PUBLIC_KEY=" "$STATE_FILE" | cut -d"'" -f2 || true)
  fi

  local hostname_str=$(hostname 2>/dev/null || echo "alpine")
  local fallback_remark="${hostname_str}-AnyReality"

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

  read -rp "👉 修改节点备注名称 (当前: ${current_remark:-$fallback_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-${current_remark:-$fallback_remark}}

  PRIVATE_KEY="$current_private_key"
  PUBLIC_KEY="$current_public_key"

  generate_or_use_key
  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$SB_BINARY" ]]; then
    error "当前系统未安装该版本 Sing-box，无法执行更新。"
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

  echo -ne "正在覆盖独立二进制核心文件 ... "
  local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
  tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
  
  local _extracted_binary=$(find "$_tmpdir_extract" -type f -name "sing-box" | head -n 1)
  if [[ -n "$_extracted_binary" ]]; then
    if cp "$_extracted_binary" "$EXECUTABLE_INSTALL_PATH" && chmod 755 "$EXECUTABLE_INSTALL_PATH"; then
      echo "成功"
    else
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "覆盖核心失败" && return 1
    fi
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "解压错误" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  info "正在重启独立服务以应用更新..."
  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" ]; then
    rc_service "$SB_SERVICE_NAME" restart >/dev/null 2>&1 || true
    if rc_service "$SB_SERVICE_NAME" status >/dev/null 2>&1; then
      info "独立核心已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但 OpenRC 重启服务失败。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "独立核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" ]; then
    rc_service "$SB_SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc_update del "$SB_SERVICE_NAME" default >/dev/null 2>&1 || true
    remove_file "$INIT_SERVICE_DIR/$SB_SERVICE_NAME"
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -f "$SB_CONFIG" "$STATE_FILE"
  rm -rf "$CONFIG_DIR" "$SB_DIR"

  info "已完全卸载该独立 Sing-box 服务、配置文件与状态文件。"
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
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo "---------------------------------------------"
  echo -e "${GREEN}👉 v2rayN 分享链接:${RESET}"
  echo -e "${YELLOW}${v2rayn_link}${RESET}"
  echo "---------------------------------------------"
}

# ================== SNI 优选 ==================
select_best_sni() {
    info "开始优选 SNI 延迟测试"

    local SNIS=(
    amd.com
    apps.mzstatic.com
    aws.com
    azure.microsoft.com
    beacon.gtv-pub.com
    bing.com
    catalog.gamepass.com
    cdn.bizibly.com
    cdn-dynmedia-1.microsoft.com
    devblogs.microsoft.com
    fpinit.itunes.apple.com
    go.microsoft.com
    gray-config-prod.api.arc-cdn.net
    gray.video-player.arcpublishing.com
    images.nvidia.com
    r.bing.com
    services.digitaleast.mobi
    snap.licdn.com
    statici.icloud.com
    tag.demandbase.com
    tag-logger.demandbase.com
    ts1.tc.mm.bing.net
    ts2.tc.mm.bing.net
    vs.aws.amazon.com
    www.apple.com
    www.icloud.com
    www.microsoft.com
    www.oracle.com
    www.xbox.com
    www.xilinx.com
    xp.apple.com
    )

    BEST_SNI=""
    BEST_TIME=999999

    for sni in "${SNIS[@]}"; do
        start=$(date +%s%N)

        # 增加对 Alpine 环境下 openssl 超时和断连的处理规范
        timeout 3 openssl s_client \
            -connect ${sni}:443 \
            -servername ${sni} \
            -brief </dev/null >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            end=$(date +%s%N)
            cost=$(( (end - start) / 1000000 ))

            echo "[SNI] $sni -> ${cost}ms"

            if [ $cost -lt $BEST_TIME ]; then
                BEST_TIME=$cost
                BEST_SNI=$sni
            fi
        fi
    done

    if [ -n "$BEST_SNI" ]; then
        info "最优 SNI: $BEST_SNI (${BEST_TIME}ms)"
        echo "$BEST_SNI"
        return 0
    else
        warn "未找到可用 SNI"
        return 1
    fi
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

    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN} Sing-box AnyReality 独立共存面板     ${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}=====================================${RESET}"
    echo -e "${GREEN} 1. 安装 AnyReality 独立服务${RESET}"
    echo -e "${GREEN} 2. 更新 AnyReality 独立内核${RESET}"
    echo -e "${GREEN} 3. 卸载 AnyReality 独立服务${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 AnyReality${RESET}"
    echo -e "${GREEN} 6. 停止 AnyReality${RESET}"
    echo -e "${GREEN} 7. 重启 AnyReality${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN}10. SNI域名优选✨${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}=====================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_singbox; pause ;;
      2) update_singbox; pause ;;
      3) uninstall_singbox; pause ;;
      4) modify_config; pause ;;
      5) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" ]; then
          rc_service "$SB_SERVICE_NAME" start && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台独立启动！"
        fi
        pause ;;
      6) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" ]; then
          rc_service "$SB_SERVICE_NAME" stop && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台独立进程已终止！"
        fi
        pause ;;
      7) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/$SB_SERVICE_NAME" ]; then
          rc_service "$SB_SERVICE_NAME" restart && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台独立进程已重启！"
        fi
        pause ;;
      8) 
        if [[ -f /var/log/messages ]]; then
          tail -n 50 /var/log/messages | grep "$SB_SERVICE_NAME" || tail -n 50 /var/log/messages
        else
          warn "未找到系统日志文件，如在精简容器中运行，建议直接观察前端或进程状态。"
        fi
        pause ;;
      9) showconf; pause ;;
      10) select_best_sni; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
