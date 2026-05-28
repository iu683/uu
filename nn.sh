#!/usr/bin/env bash
#
# Xray (VLESS-Encryption) 核心控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BINARY="/usr/local/bin/xray"
readonly STATE_FILE="/root/xray_encryption_info.txt"
readonly LINK_FILE="/root/xray_vless_encryption_link.txt"
XRAY_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
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
  command mktemp "$@" "xrayservinst.XXXXXXXXXX"
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

check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
}

get_installed_version() {
  if [[ -f "$XRAY_BINARY" ]]; then
    local version_out
    version_out=$("$XRAY_BINARY" version 2>/dev/null | head -n 1 || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | awk '{print $2}' || echo "未知"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

check_xray_version() {
  if [ ! -f "$XRAY_BINARY" ]; then return 1; fi
  if ! $XRAY_BINARY help 2>/dev/null | grep -q "vlessenc"; then return 1; fi
  return 0
}

execute_official_script() {
  local args="$*"
  info "Xray ($args)..."
  if ! bash <(curl -Ls "$XRAY_INSTALL_SCRIPT_URL") $args; then
    error "官方安装脚本执行失败！"
    return 1
  fi
}

get_public_ip() {
  local ip=''
  for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
    ip=$(curl -4s --max-time 5 "$url" 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  hostname -I | awk '{print $1}'
}

# =========================================================
# 3. 面板辅助网络与状态扩展函数
# =========================================================
get_sb_status() {
  if has_command systemctl && systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$XRAY_BINARY run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$XRAY_CONFIG" ]]; then
    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "")
    echo "${port:- -}"
  else echo "-"; fi
}

generate_uuid() {
  if [ -f "$XRAY_BINARY" ] && [ -x "$XRAY_BINARY" ]; then
    $XRAY_BINARY uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

generate_vless_encryption_config() {
  local vlessenc_output
  vlessenc_output=$($XRAY_BINARY vlessenc 2>/dev/null || true)
  if [ -z "$vlessenc_output" ]; then
    error "生成 VLESS Encryption 配置失败"
    return 1
  fi

  local decryption_config=""
  local encryption_config=""
  local in_mlkem_section=false

  set +e
  while IFS= read -r line; do
    if [[ "$line" == *"Authentication: ML-KEM-768, Post-Quantum"* ]]; then
      in_mlkem_section=true
      continue
    fi

    if [ "$in_mlkem_section" = true ]; then
      if [[ "$line" == *'"decryption":'* ]]; then
        decryption_config=$(echo "$line" | sed 's/.*"decryption": "\([^"]*\)".*/\1/')
      elif [[ "$line" == *'"encryption":'* ]]; then
        if echo "$line" | grep -q '.*"encryption": "[^"]*"'; then
          encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\)".*/\1/')
        else
          encryption_config=$(echo "$line" | sed 's/.*"encryption": "\([^"]*\).*/\1/')
          read -r next_line
          encryption_config="${encryption_config}${next_line}"
          encryption_config=$(echo "$encryption_config" | tr -d '"' | tr -d '[:space:]')
        fi
        break
      fi
    fi
  done <<< "$vlessenc_output"
  set -e

  if [ -z "$decryption_config" ] || [ -z "$encryption_config" ]; then
    error "无法解析 VLESS Encryption 配置。"
    return 1
  fi

  echo "${decryption_config}|${encryption_config}"
}

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
  # 彻底重写状态底座
  rm -f "$STATE_FILE"
  echo "$ENCRYPTION" > "$STATE_FILE"

  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg decryption "$DECRYPTION" \
    --arg flow "xtls-rprx-vision" \
  '{
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": $uuid, "flow": $flow}],
        "decryption": $decryption
      }
    }],
    "outbounds": [{
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    }]
  }' > "$XRAY_CONFIG"

  chmod 644 "$XRAY_CONFIG"
  
  SERVER_IP=$(get_public_ip)
  cat << EOF >> "$STATE_FILE"
PORT='${PORT}'
UUID='${UUID}'
REMARK='${REMARK}'
SERVER_IP='${SERVER_IP}'
EOF

  # 强制清除旧的残留进程，避免端口占用导致死锁
  pkill -f "$XRAY_BINARY run" || true

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
    if systemctl is-active --quiet xray 2>/dev/null; then
      info "Xray (VLESS-Encryption) 服务配置并启动成功！"
    else
      error "Xray 服务启动失败，请运行 'journalctl -u xray -f' 查看错误日志。"
    fi
  else
    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
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

inst_singbox() {
  check_environment
  
  if [[ -f "$XRAY_CONFIG" ]]; then
    warn "系统检测到已存在配置。如果是要修改配置，请在菜单中选择选项 4。"
    read -rp "是否执意重新安装？(旧配置将被覆盖) [y/N]: " CONFIRM_REINST
    [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
  fi

  info "🧹 正在清理前置依赖并准备下载..."
  if ! command -v xray >/dev/null 2>&1; then
    if ! execute_official_script "install"; then
      error "Xray 核心安装失败！请检查网络连接。"
      return 1
    fi
  else
    info "系统已存在 xray 核心组件，跳过基础安装。"
  fi

  if ! check_xray_version; then
    error "当前 Xray 核心不支持 VLESS Encryption，正在强制拉取最新版..."
    execute_official_script "install"
  fi

  local encryption_info=$(generate_vless_encryption_config)
  if [ -z "$encryption_info" ]; then return 1; fi

  DECRYPTION=$(echo "$encryption_info" | cut -d'|' -f1)
  ENCRYPTION=$(echo "$encryption_info" | cut -d'|' -f2)

  # 全新随机默认值（默认高强度随机端口）
  local rand_port=$(shuf -i 10000-65535 -n 1)
  local rand_uuid=$(generate_uuid)
  local hostname_str=$(hostname 2>/dev/null || echo "linux")
  local default_remark="${hostname_str}-VLESS-E"

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$rand_port}

  read -rp "👉 请输入UUID (默认随机: ${rand_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$rand_uuid}

  read -rp "👉 请输入节点备注名称 (默认: ${default_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-$default_remark}

  write_and_show_config
}

modify_config() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "未找到正在运行的配置文件，请先选择选项 1 安装节点。"
    return 1
  fi

  info "正在读取现有节点配置与密钥..."
  
  # 精准从当前运行的 config.json 中抓取原有密钥，确保绝不更改
  local current_port=$(jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null)
  local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONFIG" 2>/dev/null)
  local current_decryption=$(jq -r '.inbounds[0].settings.decryption // empty' "$XRAY_CONFIG" 2>/dev/null)
  local current_encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null || echo "")

  if [[ -z "$current_decryption" || -z "$current_encryption" ]]; then
    error "未能成功读取原有的加解密密钥，为防不通，已停止修改。请先通过选项 1 重新安装。"
    return 1
  fi

  local current_remark=""
  if [[ -f "$STATE_FILE" ]]; then
    current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || true)
  fi

  echo "---------------------------------------------"
  echo -e "${YELLOW}提示：直接敲回车(Enter)将保持括号内的当前值不变${RESET}"
  echo "---------------------------------------------"

  read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$current_port}

  read -rp "👉 修改UUID (当前: ${current_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$current_uuid}

  read -rp "👉 修改节点备注名称 (当前: ${current_remark:-VLESS-E}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-${current_remark:-VLESS-E}}

  # 把旧密钥原封不动地继承下来，拒绝重新生成
  DECRYPTION="$current_decryption"
  ENCRYPTION="$current_encryption"

  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$XRAY_BINARY" ]]; then
    error "当前系统未安装 Xray，无法执行更新。"
    return 1
  fi

  warn "即将开始平滑更新..."
  if ! execute_official_script "install"; then
    error "Xray 核心更新失败！"
    return 1
  fi

  info "正在重启 Xray 服务以应用更新..."
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl restart xray >/dev/null 2>&1 || true
    if systemctl is-active --quiet xray 2>/dev/null; then
      info "Xray 已成功平滑更新！"
    else
      error "核心更新成功，但服务重启失败。"
    fi
  else
    pkill -f "$XRAY_BINARY run" || true
    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
    info "Xray 核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  if has_command systemctl; then
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
  else
    pkill -f "$XRAY_BINARY run" || true
  fi
  
  if execute_official_script "remove --purge"; then
    rm -f "$LINK_FILE" "$STATE_FILE" "$XRAY_CONFIG"
    info "已完全卸载 Xray、配置文件与状态文件。"
  else
    error "Xray 卸载失败！"
  fi
}

showconf() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "未找到任何安装配置底座，请先安装节点。"
    return 1
  fi

  local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
  local port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
  local encryption=$(head -n 1 "$STATE_FILE" 2>/dev/null)
  local server_ip=$(get_public_ip)
  
  local current_remark="VLESS-E"
  if [[ -f "$STATE_FILE" ]]; then
    current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || echo "VLESS-E")
  fi

  local encoded_remark=$(jq -rn --arg x "$current_remark" '$x|@uri')
  local address_for_url=$server_ip
  if [[ $server_ip == *":"* ]]; then address_for_url="[${server_ip}]"; fi

  local vless_link="vless://${uuid}@${address_for_url}:${port}?encryption=${encryption}&flow=xtls-rprx-vision&type=tcp&security=none#${encoded_remark}"
  echo "$vless_link" > "$LINK_FILE"

  echo -e "${GREEN}====== VLESS-Encryption 节点配置信息 ======${RESET}"
  echo -e "${GREEN}服务器公网 IP :${RESET} ${server_ip}"
  echo -e "${GREEN}服务监听端口   :${RESET} ${port}"
  echo -e "${GREEN}用户 UUID      :${RESET} ${uuid}"
  echo -e "${GREEN}协议与加密     :${RESET} VLESS Encryption (native + 0-RTT + ML-KEM-768)"
  echo -e "${GREEN}推荐底层流控   :${RESET} xtls-rprx-vision"
  echo -e "${GREEN}节点自定义备注 :${RESET} ${current_remark}"
  echo "---------------------------------------------"
  echo -e "${GREEN}👉 V2rayN  分享链接 (已存至 $LINK_FILE):${RESET}"
  echo -e "${YELLOW}${vless_link}${RESET}"
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
    echo -e "${GREEN}    Xray VLESS-Encryption 面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 VLESS-Encryption${RESET}" 
    echo -e "${GREEN}2. 更新 VLESS-Encryption${RESET}"
    echo -e "${GREEN}3. 卸载 VLESS-Encryption${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 VLESS-Encryption${RESET}"
    echo -e "${GREEN}6. 停止 VLESS-Encryption${RESET}"
    echo -e "${GREEN}7. 重启 VLESS-Encryption${RESET}"
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
          systemctl start xray && info "服务已成功启动！"
        else
          pkill -f "$XRAY_BINARY run" || true
          "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop xray && info "服务已成功停止！"
        else
          pkill -f "$XRAY_BINARY run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart xray && info "服务已成功重启！"
        else
          pkill -f "$XRAY_BINARY run" || true
          "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u xray.service -n 50 --no-pager
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
