#!/usr/bin/env bash
#
# Xray (VLESS-REALITY-xhttp) 核心控制面板 [2026 密钥无损锁定版]
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
readonly STATE_FILE="/root/xray_reality_info.txt"
readonly LINK_FILE="/root/xray_vless_reality_link.txt"
readonly XRAY_PUBLIC_KEY_FILE="/usr/local/etc/xray/public.key"
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

generate_reality_keys() {
    info "正在生成 Reality 密钥..."
    local key_pair

    if ! key_pair=$(timeout 10 "$XRAY_BINARY" x25519 2>/dev/null); then
        error "Reality 密钥生成失败"
        return 1
    fi

    local private_key
    private_key=$(echo "$key_pair" \
        | grep -i "Private" \
        | awk -F ': ' '{print $2}' \
        | tr -d '\r ')

    local public_key
    public_key=$(echo "$key_pair" \
        | grep -i "Public" \
        | awk -F ': ' '{print $2}' \
        | tr -d '\r ')

    if [[ -z "${private_key:-}" || -z "${public_key:-}" ]]; then
        error "生成的密钥对无效或为空"
        return 1
    fi

    mkdir -p "$(dirname "$XRAY_PUBLIC_KEY_FILE")"
    echo "$public_key" > "$XRAY_PUBLIC_KEY_FILE"
    echo "${private_key}|${public_key}"
}

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
  rm -f "$STATE_FILE"

  # 保护已有路径或生成全新路径
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    XHTTP_PATH="/$(openssl rand -hex 4 2>/dev/null || echo "xhttp")$(shuf -i 1000-9999 -n 1)"
  fi

  # 使用 jq 安全拼装
  jq -n \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg target "$DEST" \
    --arg privateKey "$PRIVATE_KEY" \
    --arg shortId "$SHORT_ID" \
    --arg path "$XHTTP_PATH" \
  '{
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": $uuid}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": ($target + ":443"),
          "serverNames": [$target],
          "privateKey": $privateKey,
          "shortIds": [$shortId]
        },
        "xhttpSettings": {
          "host": "",
          "path": $path,
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
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
  cat << EOF > "$STATE_FILE"
PORT='${PORT}'
UUID='${UUID}'
REMARK='${REMARK}'
SERVER_IP='${SERVER_IP}'
DEST='${DEST}'
SERVER_NAME='${DEST}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
XHTTP_PATH='${XHTTP_PATH}'
EOF

  pkill -f "$XRAY_BINARY run" || true

  local service_file="/etc/systemd/system/xray.service"
  if [[ -f "$service_file" ]]; then
    sed -i '/User=nobody/d' "$service_file" 2>/dev/null || true
  fi

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
    if systemctl is-active --quiet xray 2>/dev/null; then
      info "Xray 配置应用并启动成功！"
    else
      error "Xray 服务启动失败，请运行 'journalctl -u xray -f' 查看错误日志。"
    fi
  else
    "$XRAY_BINARY" run -c "$XRAY_CONFIG" >/dev/null 2>&1 &
    info "非 systemd 环境，程序已挂载至后台运行。"
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi

  showconf
}

# =========================================================
# 5. 主流程控制模块与无损配置继承
# =========================================================
inst_singbox() {
  check_environment
  
  if [[ -f "$XRAY_CONFIG" ]]; then
    warn "系统检测到已存在配置。如果是要修改端口，请直接在菜单中选择选项 4。"
    read -rp "是否执意重新安装？(旧配置和旧密钥将被完全覆盖) [y/N]: " CONFIRM_REINST
    [[ "$CONFIRM_REINST" != "y" && "$CONFIRM_REINST" != "Y" ]] && return 0
  fi

  info "🧹 正在准备下载与全新安装..."
  if ! command -v xray >/dev/null 2>&1; then
    if ! execute_official_script "install"; then
      error "Xray 核心安装失败！"
      return 1
    fi
  fi

  local keys
  keys=$(generate_reality_keys)
  if [ -z "$keys" ]; then return 1; fi
  PRIVATE_KEY=$(echo "$keys" | cut -d'|' -f1)
  PUBLIC_KEY=$(echo "$keys" | cut -d'|' -f2)
  SHORT_ID=$(openssl rand -hex 8 2>/dev/null || echo "a1b2c3d4e5f67890")

  local rand_port=$(shuf -i 10000-65535 -n 1)
  local rand_uuid=$(generate_uuid)
  XHTTP_PATH="/$(openssl rand -hex 4 2>/dev/null || echo "xhttp")$(shuf -i 1000-9999 -n 1)"

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$rand_port}

  read -rp "👉 请输入UUID (默认随机: ${rand_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$rand_uuid}

  read -rp "👉 请输入REALITY目标/伪装域名 (默认: www.amazon.com): " INPUT_DEST
  DEST=${INPUT_DEST:-"www.amazon.com"}

  read -rp "👉 请输入节点备注名称 (默认: VLESS-REALITY-xhttp): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-"VLESS-REALITY-xhttp"}

  write_and_show_config
}

# ================== 核心安全修改逻辑 ==================
modify_config() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "未找到现有的 Xray 配置文件，请先选择选项 1 安装节点。"
    return 1
  fi

  info "🔒 正在从原配置文件中无损读取现有密钥、证书及混淆特征..."

  # 【核心安全设计】：直接用 jq 从正在运行的配置文件中完美把公钥、私钥和旧参数扒出来
  PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null || echo "")
  SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")
  XHTTP_PATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONFIG" 2>/dev/null || echo "/xhttp")
  
  # 获取原公钥（如果备份存在则读备份，否则读状态文件）
  if [[ -f "$XRAY_PUBLIC_KEY_FILE" ]]; then
    PUBLIC_KEY=$(cat "$XRAY_PUBLIC_KEY_FILE")
  else
    PUBLIC_KEY=$(grep -E "^PUBLIC_KEY=" "$STATE_FILE" | cut -d"'" -f2 || echo "")
  fi

  # 兜底校验，防止读出不完整数据破坏服务
  if [[ -z "$PRIVATE_KEY" || "$PRIVATE_KEY" == "null" ]]; then
    error "未能从 config.json 提取到有效的 REALITY 私钥！为了防止配置损坏，已取消修改。"
    return 1
  fi

  # 获取当前其他参数作展示
  local current_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
  local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "")
  local current_dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.target' "$XRAY_CONFIG" 2>/dev/null | cut -d':' -f1 || echo "www.amazon.com")
  local current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || echo "VLESS-REALITY-xhttp")

  echo "---------------------------------------------"
  echo -e "${YELLOW}提示：密钥与混淆特征已在后台安全锁定。直接敲回车将保持原有值。${RESET}"
  echo "---------------------------------------------"

  read -rp "👉 修改监听端口 (当前: ${current_port}): " INPUT_PORT
  PORT=${INPUT_PORT:-$current_port}

  read -rp "👉 修改UUID (当前: ${current_uuid}): " INPUT_UUID
  UUID=${INPUT_UUID:-$current_uuid}

  read -rp "👉 修改REALITY目标/伪装域名 (当前: ${current_dest}): " INPUT_DEST
  DEST=${INPUT_DEST:-$current_dest}

  read -rp "👉 修改节点备注名称 (当前: ${current_remark}): " INPUT_REMARK
  REMARK=${INPUT_REMARK:-$current_remark}

  # 写入并重新启动服务
  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$XRAY_BINARY" ]]; then
    error "当前系统未安装 Xray，无法执行更新。"
    return 1
  fi
  if ! execute_official_script "install"; then
    error "Xray 核心更新失败！"
    return 1
  fi
  if has_command systemctl; then
    systemctl daemon-reload && systemctl restart xray >/dev/null 2>&1 || true
  fi
  info "Xray 核心已更新并重启。"
}

uninstall_singbox() {
  if has_command systemctl; then
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
  fi
  pkill -f "$XRAY_BINARY run" || true
  if execute_official_script "remove --purge"; then
    rm -f "$LINK_FILE" "$STATE_FILE" "$XRAY_CONFIG" "$XRAY_PUBLIC_KEY_FILE"
    info "已完全清除所有组件与遗留文件。"
  fi
}

showconf() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "未找到任何安装配置底座，请先安装节点。"
    return 1
  fi

  # 直接从生成的最新 JSON 里抓取信息展示，保持 absolute 的准度
  local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
  local port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
  local dest=$(jq -r '.inbounds[0].streamSettings.realitySettings.target' "$XRAY_CONFIG" 2>/dev/null | cut -d':' -f1)
  local sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null)
  local xpath=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONFIG" 2>/dev/null)
  
  if [[ -f "$XRAY_PUBLIC_KEY_FILE" ]]; then
    PUBLIC_KEY=$(cat "$XRAY_PUBLIC_KEY_FILE")
  else
    PUBLIC_KEY=$(grep -E "^PUBLIC_KEY=" "$STATE_FILE" | cut -d"'" -f2 || echo "")
  fi

  local server_ip=$(grep -E "^SERVER_IP=" "$STATE_FILE" | cut -d"'" -f2 || get_public_ip)
  local current_remark=$(grep -E "^REMARK=" "$STATE_FILE" | cut -d"'" -f2 || echo "VLESS-REALITY-xhttp")

  local encoded_remark=$(jq -rn --arg x "$current_remark" '$x|@uri')
  local encoded_path=$(jq -rn --arg x "$xpath" '$x|@uri')
  local address_for_url=$server_ip
  if [[ $server_ip == *":"* ]]; then address_for_url="[${server_ip}]"; fi

  local vless_link="vless://${uuid}@${address_for_url}:${port}?security=reality&sni=${dest}&pbk=${PUBLIC_KEY}&sid=${sid}&fp=chrome&type=xhttp&mode=auto&path=${encoded_path}#${encoded_remark}"
  echo "$vless_link" > "$LINK_FILE"

  echo -e "${GREEN}====== VLESS-REALITY-xhttp 节点配置信息 ======${RESET}"
  echo -e "${GREEN}服务器公网 IP   :${RESET} ${server_ip}"
  echo -e "${GREEN}服务监听端口     :${RESET} ${port}"
  echo -e "${GREEN}用户 UUID        :${RESET} ${uuid}"
  echo -e "${GREEN}传输层/安全协议  :${RESET} xhttp (mode: auto) + REALITY"
  echo -e "${GREEN}XHTTP 混淆路径   :${RESET} ${xpath}"
  echo -e "${GREEN}REALITY 伪装目标 :${RESET} ${dest}:443"
  echo -e "${GREEN}REALITY 公钥     :${RESET} ${PUBLIC_KEY}"
  echo -e "${GREEN}REALITY 短 ID    :${RESET} ${sid}"
  echo -e "${GREEN}节点自定义备注   :${RESET} ${current_remark}"
  echo "---------------------------------------------"
  echo -e "${GREEN}👉 v2rayN 分享链接:${RESET}"
  echo -e "${YELLOW}${vless_link}${RESET}"
  echo "---------------------------------------------"
}

menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_sb_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Xray VLESS-REALITY-xhttp 面板 ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 VLESS-REALITY-xhttp${RESET}" 
    echo -e "${GREEN}2. 更新 VLESS-REALITY-xhttp${RESET}"
    echo -e "${GREEN}3. 卸载 VLESS-REALITY-xhttp${RESET}"
    echo -e "${GREEN}4. 修改配置 (无损继承密钥/路径)${RESET}"
    echo -e "${GREEN}5. 启动 VLESS-REALITY-xhttp${RESET}"
    echo -e "${GREEN}6. 停止 VLESS-REALITY-xhttp${RESET}"
    echo -e "${GREEN}7. 重启 VLESS-REALITY-xhttp${RESET}"
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
      5) if has_command systemctl; then systemctl start xray; fi; pause ;;
      6) if has_command systemctl; then systemctl stop xray; fi; pause ;;
      7) if has_command systemctl; then systemctl restart xray; fi; pause ;;
      8) if has_command systemctl; then journalctl -u xray.service -n 50 --no-pager; fi; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入。"; sleep 1 ;;
    esac
  done
}

menu "$@"
