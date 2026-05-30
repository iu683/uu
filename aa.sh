#!/usr/bin/env bash
#
# Sing-box (VMess + WS) Alpine 专属核心控制面板 - V3 (彻底修复版)
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
readonly SB_DIR="/root/vmessws"
readonly STATE_FILE="/etc/vmessws-singbox.env"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
INIT_SERVICE_DIR="/etc/init.d"
CONFIG_DIR="/etc/sing-box"
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
    # 【彻底修复】放弃 install 级联指令，用最稳妥的原生组合拳创建
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

  # 确保 Alpine 环境具备基本工具
  has_command bash || install_software bash
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
  local version="$1"
  local dest_file="$2"
  local ver_num="${version#v}"
  local filename="sing-box-${ver_num}-${OPERATING_SYSTEM}-${ARCHITECTURE}.tar.gz"
  local download_url="${REPO_URL}/releases/download/${version}/${filename}"

  info "正在下载 Sing-box ${version} (${ARCHITECTURE}) ..."
  if ! curl -sS "$download_url" -o "$dest_file"; then
    error "下载失败，请检查网络连接或 GitHub 连通性。"
    return 1
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

tpl_singbox_server_openrc_base() {
  cat << 'EOF'
#!/sbin/openrc-run

description="Sing-box Service"
supervisor="supervise-daemon"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
extra_started_commands="reload"

depend() {
    need net
    after firewall
}

reload() {
    ebegin "Reloading sing-box configuration"
    supervise-daemon --signal HUP --name sing-box
    eend $?
}
EOF
}

# =========================================================
# 3. 面板辅助网络与状态扩展函数
# =========================================================
get_sb_status() {
  if has_command rc-service && rc-service sing-box status >/dev/null 2>&1; then
    echo -e "${GREEN}● 运行中 (OpenRC)${RESET}"
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

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
  mkdir -p "$CONFIG_DIR"

  local headers_json="{}"
  if [[ -n "${WSHOST}" ]]; then
    headers_json="{\"Host\": \"${WSHOST}\"}"
  fi

  cat << EOF > "$SB_CONFIG"
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WSPATH}",
        "headers": ${headers_json},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
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
UUID='${UUID}'
WSPATH='${WSPATH}'
WSHOST='${WSHOST}'
REMARK='${REMARK}'
SERVER_IP='${SERVER_IP}'
EOF
  chmod 600 "$STATE_FILE"

  # 检查是否支持并存在 OpenRC 服务托管环境
  if has_command rc-service && [ -d "$INIT_SERVICE_DIR" ]; then
    rc_update add sing-box default >/dev/null 2>&1 || true
    rc_service sing-box restart >/dev/null 2>&1 || true
    if rc_service sing-box status >/dev/null 2>&1; then
      info "Sing-box (VMess+WS) 服务通过 OpenRC 启动成功！"
    else
      error "Sing-box 服务启动失败，请检查 /var/log/messages 查看错误日志。"
    fi
  else
    # 极简无守护或 Docker 环境，直接以传统 PID 后台常驻模式运行
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "提示：未检测到 OpenRC 运行环境，程序已采用常驻进程 (PID-Mode) 后台挂载运行。"
  fi
  
  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================

inst_singbox() {
  check_environment
  
  if [[ -f "$SB_CONFIG" ]]; then
    warn "系统检测到已存在配置。如果是要修改配置，请在菜单中选择选项 4。"
    read -rp "是否执意重新安装？(旧配置将被覆盖) [y/N]: " CONFIRM_REINST
    [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
  fi

  info "🧹 正在清理前置依赖并准备下载..."
  if ! command -v sing-box >/dev/null 2>&1; then
    local latest_version=$(get_latest_version)
    
    local _tmpfile_tar=$(mktemp)
    if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
      rm -f "$_tmpfile_tar" && return 1
    fi

    echo -ne "正在解压并安装二进制可执行文件 ... "
    local _tmpdir_extract=$(command mktemp -d -t "sbtar.XXXXXXXXXX")
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
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "未找到核心文件" && return 1
    fi
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract"
  else
    info "系统已存在 sing-box 核心组件，跳过基础安装。"
  fi

  # 写入服务脚本（采用完全兼容 BusyBox 的 install_content 原生重构版）
  install_content "0755" "$(tpl_singbox_server_openrc_base)" "$INIT_SERVICE_DIR/sing-box" "1"

  # 兼容 Alpine 无 shuf 的随机端口生成
  local hostname_str=$(hostname 2>/dev/null || echo "alpine")
  local rand_port=$(awk 'BEGIN{srand();print int(rand()*(65535-10000+1))+10000}')
  local rand_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  local rand_path="/$(python3 -c "import secrets; print(secrets.token_hex(4))")"
  local default_remark="${hostname_str}-vmessws"

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$rand_port}

  read -rp "👉 请输入 VMess UUID (默认随机: ${rand_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$rand_uuid}

  read -rp "👉 请输入 WebSocket 路径 (默认随机: ${rand_path}): " INPUT_WSPATH
  WSPATH=${INPUT_WSPATH:-$rand_path}

  read -rp "👉 请输入 WebSocket Host 伪装域名 (默认留空): " INPUT_WSHOST
  WSHOST=${INPUT_WSHOST:-""}

  read -rp "👉 请输入节点备注名称 (默认: ${default_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-$default_remark}

  write_and_show_config
}

modify_config() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "未找到正在运行的配置文件，请先选择选项 1 安装节点。"
    return 1
  fi

  info "正在读取现有 VMess 节点配置..."
  local current_port=$(jq -r '.inbounds[0].listen_port // empty' "$SB_CONFIG" 2>/dev/null)
  local current_uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$SB_CONFIG" 2>/dev/null)
  local current_path=$(jq -r '.inbounds[0].transport.path // empty' "$SB_CONFIG" 2>/dev/null)
  local current_host=$(jq -r '.inbounds[0].transport.headers.Host // empty' "$SB_CONFIG" 2>/dev/null)
  
  local current_remark=""
  if [[ -f "$STATE_FILE" ]]; then
    current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
  fi

  local hostname_str=$(hostname 2>/dev/null || echo "alpine")
  local fallback_remark="${hostname_str}-vmessws"

  echo "---------------------------------------------"
  echo -e "${YELLOW}提示：直接敲回车(Enter)将保持括号内的当前值不变${RESET}"
  echo "---------------------------------------------"

  read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$current_port}

  read -rp "👉 修改 VMess UUID (当前: ${current_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$current_uuid}

  read -rp "👉 修改 WebSocket 路径 (当前: ${current_path}): " INPUT_WSPATH
  WSPATH=${INPUT_WSPATH:-$current_path}

  read -rp "👉 修改 WebSocket Host 伪装域名 (当前: ${current_host:-未配置/留空}): " INPUT_WSHOST
  if [[ -z "$INPUT_WSHOST" ]]; then
    WSHOST="$current_host"
  else
    WSHOST="$INPUT_WSHOST"
  fi

  read -rp "👉 修改节点备注名称 (当前: ${current_remark:-$fallback_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-${current_remark:-$fallback_remark}}
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
  local _tmpdir_extract=$(command mktemp -d -t "sbtar.XXXXXXXXXX")
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

  info "正在重启 Sing-box 服务以应用更新..."
  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
    rc_service sing-box restart >/dev/null 2>&1 || true
    if rc_service sing-box status >/dev/null 2>&1; then
      info "Sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但 OpenRC 重启服务失败，请检查系统日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "Sing-box 核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
    rc_service sing-box stop >/dev/null 2>&1 || true
    rc_update del sing-box default >/dev/null 2>&1 || true
    remove_file "$INIT_SERVICE_DIR/sing-box"
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -f "$SB_CONFIG" "$STATE_FILE"
  rm -rf "$CONFIG_DIR" "$SB_DIR"

  info "已卸载 Sing-box、配置文件与状态管理底座。"
}

showconf() {
  if [[ ! -f "$STATE_FILE" ]]; then
    error "未找到任何安装配置底座，请先安装节点。"
    return 1
  fi
  source "$STATE_FILE"

  local vmess_json_str
  vmess_json_str=$(cat << EOF
{
  "v": "2",
  "ps": "${REMARK}",
  "add": "${SERVER_IP}",
  "port": ${PORT},
  "id": "${UUID}",
  "aid": 0,
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${WSHOST}",
  "path": "${WSPATH}",
  "tls": "none",
  "sni": "",
  "alpn": ""
}
EOF
)
  local v2rayn_link=""
  if base64 --help 2>&1 | grep -q "\-d"; then
    v2rayn_link="vmess://$(echo -n "$vmess_json_str" | base64 | tr -d '\n\r')"
  else
    v2rayn_link="vmess://$(echo -n "$vmess_json_str" | base64 -w 0 2>/dev/null || echo -n "$vmess_json_str" | base64 | tr -d '\n\r')"
  fi

  echo -e "${GREEN}====== VMess + WebSocket 节点配置信息 ======${RESET}"
  echo -e "${GREEN}服务器公网 IP   :${RESET} ${SERVER_IP}"
  echo -e "${GREEN}服务监听端口    :${RESET} ${PORT}"
  echo -e "${GREEN}VMess 用户UUID :${RESET} ${UUID}"
  echo -e "${GREEN}传输协议类型    :${RESET} ws (WebSocket)"
  echo -e "${GREEN}WebSocket 路径 :${RESET} ${WSPATH}"
  echo -e "${GREEN}WebSocket Host :${RESET} ${WSHOST:-未配置(留空)}"
  echo -e "${GREEN}节点自定义备注 :${RESET} ${REMARK}"
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo "---------------------------------------------"
  echo -e "${GREEN}👉 v2rayN   分享链接:${RESET}"
  echo -e "${YELLOW}${v2rayn_link}${RESET}"
  echo
  echo -e "${GREEN}👉 Surge   分享链接:${RESET}"
  echo -e "${YELLOW}Vmesh+WS = vmess, $SERVER_IP, $PORT, username=$UUID, ws=true, ws-path=$WSPATH, vmess-aead=true${RESET}"
  echo "---------------------------------------------"
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
    echo -e "${GREEN}   Sing-box VMess + WS Alpine面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 VMess + WS${RESET}"
    echo -e "${GREEN}2. 更新 VMess + WS${RESET}"
    echo -e "${GREEN}3. 卸载 VMess + WS${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 VMess + WS${RESET}"
    echo -e "${GREEN}6. 停止 VMess + WS${RESET}"
    echo -e "${GREEN}7. 重启 VMess + WS${RESET}"
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
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box start && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box stop && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box restart && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if [[ -f /var/log/messages ]]; then
          tail -n 50 /var/log/messages | grep sing-box || tail -n 50 /var/log/messages
        else
          warn "未找到通用系统日志文件，可尝试通过查看后台进程状态。"
        fi
        pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
