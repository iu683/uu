#!/usr/bin/env bash
#
# Xray  VLESS-Encryption 控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eeuo pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly SERVICE_NAME="xray-vless-encry"
readonly XRAY_CONFIG="/usr/local/etc/${SERVICE_NAME}/config.json"
readonly XRAY_BINARY="/usr/local/bin/${SERVICE_NAME}"
readonly STATE_DIR="/root/Encryption"
readonly STATE_FILE="${STATE_DIR}/xray_encryption_info.txt"
readonly LINK_FILE="${STATE_DIR}/xray_vless_pure_encryption_link.txt"

# 降级备用版本
readonly BACKUP_VERSION="26.3.27"

# 终端规范颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

TMP_DIR=$(mktemp -d -t xray_enc.XXXXXX)

# ================== 自动清理垃圾 ==================
cleanup() {
  [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# 基础工具函数
info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# =========================================================
# 2. 底层网络与系统验证工具函数
# =========================================================
get_public_ip() {
  local ip
  for cmd in "curl -4fsSL --max-time 5" "wget -4qO- --timeout=5"; do
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
      ip=$($cmd "$url" 2>/dev/null || true)
      [[ -n "${ip:-}" ]] && { echo "$ip"; return 0; }
    done
  done
  for cmd in "curl -6fsSL --max-time 5" "wget -6qO- --timeout=5"; do
    for url in "https://api.ipify.org" "https://ipv6.ip.sb"; do
      ip=$($cmd "$url" 2>/dev/null || true)
      [[ -n "${ip:-}" ]] && { echo "$ip"; return 0; }
    done
  done
  return 1
}

check_port() {
  local port="$1"
  if ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then
    return 1  # 被占用
  fi
  return 0  # 未被占用
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

get_random_port() {
  local rand_port
  while true; do
    rand_port=$((RANDOM % 55536 + 10000))
    if check_port "$rand_port"; then
      echo "$rand_port"
      return 0
    fi
  done
}

is_valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l) echo "arm32-v7a" ;;
    *) error "暂不支持的系统架构: $arch"; return 1 ;;
  esac
}

get_latest_version() {
  local latest_version
  info "正在获取 GitHub 最新 Xray 版本号..."
  latest_version=$(curl -fsSL --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null || echo "")
  latest_version="${latest_version#v}"

  if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    warn "获取最新版本失败，将使用内置备用版本: v${BACKUP_VERSION}"
    echo "$BACKUP_VERSION"
  else
    info "成功获取最新版本: v${latest_version}"
    echo "$latest_version"
  fi
}

# =========================================================
# 3. 从 GitHub 下载与服务构建核心
# =========================================================
download_and_extract_xray() {
  local arch version
  arch=$(get_arch) || return 1
  version=$(get_latest_version)
  
  local download_url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip"
  local zip_file="$TMP_DIR/xray.zip"
  
  info "正在从 GitHub 下载 Xray v${version} (${arch})..."
  if ! curl -L -fsSL "$download_url" -o "$zip_file"; then
    error "从 GitHub 下载 Xray 失败，请检查网络连接。"
    return 1
  fi
  
  info "正在解压核心组件..."
  mkdir -p "$TMP_DIR/extracted"
  if ! unzip -qo "$zip_file" -d "$TMP_DIR/extracted"; then
    error "解压 Xray 失败，请确保系统已安装 unzip。"
    return 1
  fi
  
  mkdir -p "$(dirname "$XRAY_BINARY")"
  rm -f "$XRAY_BINARY"
  cp -f "$TMP_DIR/extracted/xray" "$XRAY_BINARY"
  chmod +x "$XRAY_BINARY"
  
  mkdir -p "/usr/local/share/${SERVICE_NAME}"
  cp -f "$TMP_DIR/extracted/geoip.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
  cp -f "$TMP_DIR/extracted/geosite.dat" "/usr/local/share/${SERVICE_NAME}/" 2>/dev/null || true
}

setup_systemd_service() {
  info "配置 Systemd 本地守护进程 [${SERVICE_NAME}]..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray Pure VLESS-Encryption Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
}

get_xray_status() {
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    echo -e "${RED}● 未运行${RESET}"
  fi
}

get_xray_version() {
  if [[ -x "$XRAY_BINARY" ]]; then
    "$XRAY_BINARY" version 2>/dev/null | grep -i "Xray" | head -n 1 | awk '{print $2}' || echo "未知"
  else
    echo "未安装"
  fi
}

get_listen_ip() {
  if sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q '= 1'; then
    echo "0.0.0.0"
  else
    echo "::"
  fi
}

test_config() {
  if "$XRAY_BINARY" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    return 0
  fi
  error "核心配置文件测试失败！"
  return 1
}

restart_xray() {
  systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Xray 服务启动成功"
    return 0
  fi
  error "Xray 服务启动失败，展示末尾错误日志："
  journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
  return 1
}

# =========================================================
# 4. 后量子加密资产（VLESS-Encryption）生成模块
# =========================================================
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
    error "无法解析 VLESS Encryption 后量子加解密资产。"
    return 1
  fi
  echo "${decryption_config}|${encryption_config}"
}

# =========================================================
# 5. 配置文件与纯 TCP 渲染
# =========================================================
write_config() {
  local port="$1"
  local uuid="$2"
  local decryption="$3"

  local listen_ip
  listen_ip=$(get_listen_ip)
  mkdir -p "$(dirname "$XRAY_CONFIG")"

  # 纯 VLESS-Encryption 配置结构（不依赖 TLS、Reality、无入站 Flow）
  jq -n \
    --arg listen_ip "$listen_ip" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg decryption "$decryption" \
  '{
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "listen": $listen_ip,
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": $uuid}],
        "decryption": $decryption
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }],
    "outbounds": [{
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIPv4v6"}
    }]
  }' > "$XRAY_CONFIG"
  chmod 644 "$XRAY_CONFIG"
}

generate_link() {
  local ip
  if ! ip=$(get_public_ip); then
    error "获取公网 IP 失败"
    return 1
  fi

  local uuid port encryption
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "error")
  port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
  encryption=$(cat "$STATE_FILE" 2>/dev/null || echo "none")

  local display_ip="$ip"
  [[ "$ip" =~ ":" ]] && display_ip="[$ip]"

  local hostname
  hostname=$(hostname -s 2>/dev/null | tr ' ' '_')
  [[ -z "$hostname" ]] && hostname="Xray"

  mkdir -p "$STATE_DIR"
  # 生成不包含 Reality 参数的纯 VLESS-Encryption 分享链接
  echo "vless://${uuid}@${display_ip}:${port}?encryption=${encryption}&type=tcp&security=none#${hostname}-VLESS-Enc" > "$LINK_FILE"
}

show_current_config() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "配置文件不存在，请先安装节点。"
    return
  fi

  local ip uuid port outbound_mode encryption
  ip=$(get_public_ip || echo "未知")
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
  port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
  encryption=$(cat "$STATE_FILE" 2>/dev/null || echo "未知")

  local current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null || echo "freedom")
  outbound_mode=$([[ "$current_protocol" == "socks" ]] && echo "Socks5 链式代理出口" || echo "直连 (Freedom)")

  echo -e "${GREEN}======  VLESS-Encryption 节点配置 ======${RESET}"
  echo -e "${YELLOW}服务器公网 IP   : ${ip}${RESET}"
  echo -e "${YELLOW}服务监听端口     : ${port}${RESET}"
  echo -e "${YELLOW}用户 UUID        : ${uuid}${RESET}"
  echo -e "${YELLOW}后量子客户端密钥 : ${encryption}${RESET}"
  echo -e "${YELLOW}当前出口模式     : ${outbound_mode}${RESET}"
  echo

  if [[ -f "$LINK_FILE" ]]; then
    echo -e "${GREEN}====== 👉 v2rayN 分享链接 ======${RESET}"
    cat "$LINK_FILE"
    echo "---------------------------------------------"
  fi
}

# =========================================================
# 6. 面板主功能流程模块
# =========================================================
install_xray() {
  info "开始初始化环境并下载安装 Xray 核心..."
  download_and_extract_xray || return 1
  setup_systemd_service

  info "开始静态提取后量子 VLESS Encryption 密钥..."
  local encryption_info=$(generate_vless_encryption_config) || return 1
  local decryption=$(echo "$encryption_info" | cut -d'|' -f1)
  local encryption=$(echo "$encryption_info" | cut -d'|' -f2)

  local port uuid
  while true; do
    read -rp "请输入监听端口 (回车随机分配): " input_port
    if [[ -z "$input_port" ]]; then
      port=$(get_random_port); info "分配未占用随机端口: $port"; break
    elif is_valid_port "$input_port"; then
      if ! check_port "$input_port"; then error "端口已被占用"; continue; fi
      port="$input_port"; break
    else error "端口无效"; fi
  done

  read -rp "请输入UUID (回车自动随机生成): " input_uuid
  uuid=${input_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "7415d2b8-1454-4da8-963b-4663e8322851")}

  mkdir -p "$STATE_DIR"
  echo "$encryption" > "$STATE_FILE"

  write_config "$port" "$uuid" "$decryption"
  test_config || return 1
  generate_link
  restart_xray
  show_current_config
}

update_xray() {
  if [[ ! -f "$XRAY_BINARY" ]]; then
    error "当前未执行原生安装，无法升级！"
    return 1
  fi
  info "正在平滑更新 Xray 核心..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  if ! download_and_extract_xray; then
    error "核心文件拉取失败，还原并重启服务..."
    restart_xray
    return 1
  fi
  restart_xray && info "Xray 核心已成功升级至最新版本！"
}

modify_config() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    error "配置文件不存在，请先执行安装流程。"
    return 1
  fi

  local old_port old_uuid old_decryption
  old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null)
  old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null)
  old_decryption=$(jq -r '.inbounds[0].settings.decryption' "$XRAY_CONFIG" 2>/dev/null)

  local port uuid
  while true; do
    read -rp "请输入新端口 [当前:${old_port}, 回车保持不变]: " input_port
    if [[ -z "$input_port" ]]; then port="$old_port"; break
    elif [[ "${input_port,,}" == "rand" ]]; then
      port=$(get_random_port); info "分配未占用随机端口: $port"; break
    elif is_valid_port "$input_port"; then
      if [[ "$input_port" != "$old_port" ]] && ! check_port "$input_port"; then error "端口已被占用"; continue; fi
      port="$input_port"; break
    else error "端口无效"; fi
  done

  read -rp "请输入UUID [当前:${old_uuid}, 回车不修改]: " input_uuid
  uuid=${input_uuid:-$old_uuid}

  write_config "$port" "$uuid" "$old_decryption"
  test_config || return 1
  generate_link
  restart_xray
  info "节点配置参数修改成功并已成功生效！"
}

configure_custom_socks5_outbound() {
  if [[ ! -f "$XRAY_CONFIG" ]]; then 
    error "基础配置文件未检测到，无法定制出口路径。"
    return
  fi

  local mode current_protocol tmp_file
  current_protocol=$(jq -r '.outbounds[0].protocol // "freedom"' "$XRAY_CONFIG" 2>/dev/null || echo "freedom")

  echo "---------------------------------------------"
  echo -e "当前分流出口路径: $( [[ "$current_protocol" == "socks" ]] && echo -e "${YELLOW}Socks5 代理出口${RESET}" || echo -e "${GREEN}直连本地 (Freedom)${RESET}" )"
  echo "1) 直连出口"
  echo "2) Socks5出口"
  echo "0) 取消"
  echo "---------------------------------------------"

  read -rp "请输入选项 [0-2]: " mode || true
  case "$mode" in
    1)
      tmp_file=$(mktemp)
      jq '.outbounds = [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]' "$XRAY_CONFIG" > "$tmp_file"
      mv "$tmp_file" "$XRAY_CONFIG"; chmod 644 "$XRAY_CONFIG"
      restart_xray && info "切回本地直连出口！"
      return ;;
    2) ;;
    *) info "操作已安全取消。"; return ;;
  esac

  local socks_host socks_port socks_user socks_pass
  read -rp "请输入后端 Socks5 服务器地址/IP: " socks_host || true
  [[ -z "$socks_host" ]] && return

  while true; do
    read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port || true
    [[ -z "$socks_port" ]] && socks_port=1080
    is_valid_port "$socks_port" && break || error "端口数值越界，请重新输入"
  done

  read -rp "请输入 Socks5 认证账户 (若无明文账密认证请直接敲回车跳过): " socks_user || true
  if [[ -n "$socks_user" ]]; then
    read -rs -p "请输入 Socks5 认证密码: " socks_pass || true; echo
  else socks_pass=""; fi

  tmp_file=$(mktemp)
  if [[ -n "$socks_user" ]]; then
    jq --arg host "$socks_host" --argjson port "$socks_port" --arg user "$socks_user" --arg pass "$socks_pass" \
      '.outbounds = [{"protocol": "socks", "tag": "custom-socks5-out", "settings": {"servers": [{"address": $host, "port": $port, "users": [{"user": $user, "pass": $pass}]}]}}]' \
      "$XRAY_CONFIG" > "$tmp_file"
  else
    jq --arg host "$socks_host" --argjson port "$socks_port" \
      '.outbounds = [{"protocol": "socks", "tag": "custom-socks5-out", "settings": {"servers": [{"address": $host, "port": $port}]}}]' \
      "$XRAY_CONFIG" > "$tmp_file"
  fi

  mv "$tmp_file" "$XRAY_CONFIG"; chmod 644 "$XRAY_CONFIG"
  restart_xray && info "已成功切换为 Socks5 出口"
}

uninstall_xray() {
  warn "即将彻底销毁清除 ${SERVICE_NAME} 服务与本地配置资产..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload

  rm -f "$XRAY_BINARY"
  rm -rf "/usr/local/etc/${SERVICE_NAME}"
  rm -rf "/usr/local/share/${SERVICE_NAME}"
  rm -rf "$STATE_DIR"
  info "服务已成功卸载并安全清理。"
}

# =========================================================
# 7. 菜单控制器与依赖检查
# =========================================================
show_menu() {
  clear
  local status=$(get_xray_status)
  local version=$(get_xray_version)
  local port_show="-"
  [[ -f "$XRAY_CONFIG" ]] && port_show=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "-")

  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN}    VLESS-Encryption 面板       ${RESET}"
  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN}状态   :${RESET} $status"
  echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
  echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
  echo -e "${GREEN}================================${RESET}"
  echo -e "${GREEN} 1. 安装 VLESS-Encryption${RESET}" 
  echo -e "${GREEN} 2. 更新 VLESS-Encryption${RESET}"
  echo -e "${GREEN} 3. 卸载 VLESS-Encryption${RESET}"
  echo -e "${GREEN} 4. 修改配置${RESET}"
  echo -e "${GREEN} 5. 开启 VLESS-Encryption${RESET}"
  echo -e "${GREEN} 6. 停止 VLESS-Encryption${RESET}"
  echo -e "${GREEN} 7. 重启 VLESS-Encryption${RESET}"
  echo -e "${GREEN} 8. 查看服务日志${RESET}"
  echo -e "${GREEN} 9. 查看节点配置${RESET}"
  echo -e "${GREEN}10. 配置Socks5出口${RESET}"
  echo -e "${GREEN} 0. 退出${RESET}"
  echo -e "${GREEN}================================${RESET}"
}

install_dependencies() {
  if command -v apt &>/dev/null; then
    apt update && apt install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip || true
  elif command -v dnf &>/dev/null; then
    dnf install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
  elif command -v yum &>/dev/null; then
    yum install -y jq curl wget openssl ca-certificates iproute2 coreutils unzip
  else
    error "未知的包管理器，请手动安装所需的依赖: jq, curl, wget, openssl, unzip"
    exit 1
  fi
}

pre_check() {
  if [[ $(id -u) -ne 0 ]]; then
    error "高权限环境校验失败：请切换至 root 用户再运行此脚本！"
    exit 1
  fi
  local deps=(jq curl wget openssl ss timeout unzip)
  local missing=0
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi
  done
  if [[ "$missing" -eq 1 ]]; then
    info "检测到当前环境缺少依赖，正在由本地软件源补全..."
    install_dependencies
  fi
}

main() {
  pre_check
  while true; do
    show_menu
    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_xray; pause ;;
      2) update_xray; pause ;;
      3) uninstall_xray; pause ;;
      4) modify_config; pause ;;
      5) systemctl start "${SERVICE_NAME}" 2>/dev/null || true; restart_xray; pause ;;
      6) systemctl stop "${SERVICE_NAME}" 2>/dev/null || true; info "服务停止完毕"; pause ;;
      7) restart_xray; pause ;;
      8) journalctl -u "${SERVICE_NAME}" -e --no-pager || true; pause ;;
      9) show_current_config; pause ;;
      10) configure_custom_socks5_outbound; pause ;;
      0) exit 0 ;;
      *) error "无效输入"; pause ;;
    esac
  done
}

main "$@"
