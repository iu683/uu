#!/usr/bin/env bash
#
# Alpine sing-box TUIC v5 隔离型自愈管理面板
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化（全面隔离硬编码资产）
# =========================================================
readonly SB_SERVICE_NAME="sing-box-tuic"
readonly BINARY_PATH="/usr/local/bin/sing-box-tuic"
readonly TUIC_CONFIG="/etc/sing-box-tuic/config.json"
readonly TUIC_DIR="/root/tuicV5"
readonly STATE_FILE="/etc/sing-box-tuic-standalone.env"
CONFIG_DIR="/etc/sing-box-tuic"
OPENRC_SERVICE_PATH="/etc/init.d/sing-box-tuic"
LOG_FILE="/var/log/sing-box-tuic.log"
RUN_USER="singbox"

TMP_DIR=$(mktemp -d -t sbtuic.XXXXXX)

# 颜色标准规范
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { echo; read -n 1 -s -r -p "$(echo -e ${GREEN}"按任意键返回菜单..."${RESET})" || true; echo; }

cleanup() {
  [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

is_alpine() {
  [[ -f /etc/alpine-release ]]
}

install_packages() {
  info "正在刷新 Alpine 仓库并安装核心依赖..."
  apk update
  apk add --no-cache bash curl wget tar openssl openrc iproute2 iptables jq grep sed coreutils bind-tools
}

create_user() {
  getent group "$RUN_USER" &>/dev/null || addgroup -S "$RUN_USER"
  id "$RUN_USER" &>/dev/null || adduser -S -D -H -G "$RUN_USER" -s /sbin/nologin "$RUN_USER"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) error "不支持当前架构: $(uname -m)"; exit 8 ;;
  esac
}

# =========================================================
# 2. 底层环境修复与 glibc/动态库补全
# =========================================================
check_environment() {
  if ! is_alpine; then
    error "本脚本仅支持 Alpine Linux 系统。"
    exit 95
  fi
  install_packages
  create_user
  
  # 自动补全 glibc 动态运行库，消除 Alpine 下二进制文件 not found 闪退
  if [[ -f /etc/alpine-release ]]; then
    apk info -e gcompat >/dev/null 2>&1 || apk add --no-cache gcompat >/dev/null 2>&1 || true
  fi

  # 强行激活内核 IPv4 路由转发（彻底打通端口跳跃底层屏障）
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
  echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

  # 强行加载并固化 Alpine 所需的 iptables 转发重定向内核模块
  local modules=(ip_tables iptable_nat xt_REDIRECT)
  for mod in "${modules[@]}"; do
    modprobe "$mod" >/dev/null 2>&1 || true
    if [[ -f /etc/modules ]] && ! grep -q -w "$mod" /etc/modules; then
      echo "$mod" >> /etc/modules
    fi
  done
}

get_installed_version() {
  if [[ -f "$BINARY_PATH" ]]; then
    "$BINARY_PATH" version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知版本"
  else
    echo "未安装"
  fi
}

get_latest_version() {
  info "正在从 GitHub 获取 sing-box 最新版本号..."
  local latest_v
  latest_v=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name | sed 's/^v//' 2>/dev/null)
  
  if [[ -z "$latest_v" || "$latest_v" == "null" ]]; then
    warn "通过 API 获取最新版本失败，尝试备用匹配方案..."
    latest_v=$(curl -fsSL "https://github.com/SagerNet/sing-box/releases/latest" | grep -oE 'releases/tag/v[0-9.]+' | head -n1 | sed 's|releases/tag/v||' 2>/dev/null)
  fi

  if [[ -n "$latest_v" ]]; then
    SINGBOX_VERSION="$latest_v"
    info "成功获取最新版本: v$SINGBOX_VERSION"
  else
    SINGBOX_VERSION="1.12.3"
    warn "无法获取最新版本，将使用保底版本: v$SINGBOX_VERSION"
  fi
}

# =========================================================
# 3. 精准自愈型 UDP 端口跳跃管理控制台（取代旧 iptables 函数）
# =========================================================
manage_udp_jump() {
  local action=$1
  local start=${2:-""}
  local end=${3:-""}
  local target_port=${4:-""}
  
  # 严格限定清理范围：只精准定向清除包含我们当前 TUIC 专属跳跃段或主端口的规则
  if [[ -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local old_port=$(cat "${CONFIG_DIR}/main_port.txt")
    if [[ -n "$old_port" ]]; then
      while iptables -t nat -L PREROUTING -n --line-numbers | grep -E "dports ${start}:${end}|redir ports ${old_port}" >/dev/null 2>&1; do
        local line_num=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "dports ${start}:${end}|redir ports ${old_port}" | head -n 1 | awk '{print $1}')
        [[ -z "$line_num" ]] && break
        iptables -t nat -D PREROUTING "$line_num" 2>/dev/null || break
      done
      while ip6tables -t nat -L PREROUTING -n --line-numbers | grep -E "dports ${start}:${end}|redir ports ${old_port}" >/dev/null 2>&1; do
        local line_num6=$(ip6tables -t nat -L PREROUTING -n --line-numbers | grep -E "dports ${start}:${end}|redir ports ${old_port}" | head -n 1 | awk '{print $1}')
        [[ -z "$line_num6" ]] && break
        ip6tables -t nat -D PREROUTING "$line_num6" 2>/dev/null || break
      done
    fi
  fi

  if [ "$action" == "add" ]; then
    [[ -z "$start" || -z "$end" || -z "$target_port" ]] && return 1
    
    # 内核转发自愈保障
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    
    # 采用高兼容 REDIRECT 机制：免去抓取外网 IP 烦恼，完美支持多网卡/双栈，绝不伤及其他共存脚本规则
    info "正在建立高精度 NAT 重定向链条: UDP $start-$end => 主端口 $target_port"
    iptables -t nat -I PREROUTING 1 -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "${target_port}"
    ip6tables -t nat -I PREROUTING 1 -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "${target_port}" 2>/dev/null || true
    
    # 固化保存当前跳跃范围资产
    echo "${start}-${end}" > "${CONFIG_DIR}/hopping.txt"
    
    # 固化 Alpine 开机自启：深度适配 Alpine 本地引导，保证重启不失联
    mkdir -p /etc/local.d
    cat << 'EOF' > /etc/local.d/sing-box-tuic-udp.start
#!/bin/sh
modprobe iptable_nat 2>/dev/null || true
modprobe xt_REDIRECT 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ -f "/etc/sing-box-tuic/hopping.txt" ] && [ -f "/etc/sing-box-tuic/main_port.txt" ]; then
    hop_val=$(cat "/etc/sing-box-tuic/hopping.txt")
    main_p=$(cat "/etc/sing-box-tuic/main_port.txt")
    start_p=${hop_val%-*}
    end_p=${hop_val#*-}
    if [ -n "$start_p" ] && [ -n "$end_p" ] && [ -n "$main_p" ]; then
        iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$main_p"
        ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
    fi
fi
EOF
    chmod +x /etc/local.d/sing-box-tuic-udp.start
    rc-update add local default >/dev/null 2>&1 || true
    
  elif [ "$action" == "remove" ]; then
    rm -f /etc/local.d/sing-box-tuic-udp.start
    rm -f "${CONFIG_DIR}/hopping.txt"
  fi
}

get_public_ip() {
  local ip
  for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
      ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done
  done
  echo "127.0.0.1"
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
  if rc-service "$SB_SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
    echo "RUNNING"
  else
    if pgrep -f "$BINARY_PATH run" >/dev/null 2>&1; then
      echo "RUNNING"
    else
      echo "STOPPED"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$TUIC_CONFIG" ]]; then
    local main_port jump_range="无"
    main_port=$(jq -r '.inbounds[0].listen_port // empty' "$TUIC_CONFIG" 2>/dev/null)
    [[ -f "${CONFIG_DIR}/hopping.txt" ]] && jump_range=$(cat "${CONFIG_DIR}/hopping.txt")
    
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [跳跃范围: ${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "-"; fi
}

# =========================================================
# 4. 面板节点配置生成逻辑
# =========================================================
inst_cert() {
  mkdir -p "$CONFIG_DIR/certs"

  echo "---------------------------------------------"
  echo -e "Tuic 协议证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme 脚本自动申请 (需放行 80 端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  cert_path="$CONFIG_DIR/certs/cert.pem"
  key_path="$CONFIG_DIR/certs/key.pem"

  if [[ $certInput == 2 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。请确保已暂时关闭 Web 服务。"
    fi

    if [[ -f "$cert_path" && -f "$key_path" && -s "$cert_path" && -s "$key_path" && -f "$CONFIG_DIR/certs/ca.log" ]]; then
      tuic_domain=$(cat "$CONFIG_DIR/certs/ca.log")
      info "检测到已有域名 [${tuic_domain}] 的安全区证书，正在复用..."
    else
      read -rp "请输入需要申请证书的域名: " domain
      [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
      
      info "正在检查并安装 Acme.sh 依赖..."
      local acme_cmd="/root/.acme.sh/acme.sh"
      if [[ ! -f "$acme_cmd" ]]; then
        curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum 2>/dev/null | cut -c 1-16 || echo "admin")@gmail.com
      fi
      
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      info "正在向 Let's Encrypt 申请证书..."
      if [[ "$(get_public_ip)" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      
      if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
        echo "$domain" > "$CONFIG_DIR/certs/ca.log"
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
      info "自定义证书已成功同步至配置安全区。"
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
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR/certs"
}

inst_port() {
  local default_port=""
  if [[ -f "$TUIC_CONFIG" ]]; then
    default_port=$(jq -r '.inbounds[0].listen_port // empty' "$TUIC_CONFIG" 2>/dev/null)
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

  # 写入临时记录供底层提取
  echo "$port" > "${CONFIG_DIR}/main_port.txt"

  echo "---------------------------------------------"
  echo -e "Tuic 端口群使用模式 ："
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
  jumpInput=${jumpInput:-2}

  # 准备构建新规则，提前清除老规则
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    manage_udp_jump "remove" "$start_p" "$end_p" "$port"
  fi

  if [[ $jumpInput == 2 ]]; then
    while true; do
      read -rp "设置外部跳跃起始端口 (建议10000-65535): " firstport
      read -rp "设置外部跳跃末尾端口 (必须大于起始端口): " endport
      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then break
      else error "输入无效，起始端口必须小于末尾端口，请重新输入。"; fi
    done
    # 调用全新的多脚本安全共存转发器
    manage_udp_jump "add" "$firstport" "$endport" "$port"
  else
    manage_udp_jump "remove"
    info "将继续使用单端口模式"
  fi
}

write_and_show_config() {
  local HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  local is_insecure="0"
  local skip_cert="false"
  if [[ "$tuic_domain" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

  local main_p=$(cat "${CONFIG_DIR}/main_port.txt")

  cat << EOF > "$TUIC_CONFIG"
{
  "log": {
    "level": "info",
    "output": "$LOG_FILE",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $main_p,
      "users": [
        {
          "uuid": "$auth_uuid",
          "password": "$auth_pwd"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$tuic_domain",
        "alpn": ["h3"],
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

  chmod 640 "$TUIC_CONFIG"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"

  # 如果原本存在跳跃设定，重塑刷新其防火墙链条确保无损
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    manage_udp_jump "add" "$start_p" "$end_p" "$main_p"
  fi

  mkdir -p "$TUIC_DIR"
  local hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  cat << EOF > "$TUIC_DIR/url.txt"
V6VPS 请自行替换 IP 地址为 V6
V2rayN 链接:
tuic://$auth_uuid:$auth_pwd@$last_ip:$main_p?alpn=h3&congestion_control=bbr&sni=$tuic_domain&allow_insecure=${is_insecure}${hopping_param}#$HOSTNAME-tuicv5

Surge 配置:
$HOSTNAME-tuicv5 = tuic-v5, $last_ip, $main_p, password=$auth_pwd, uuid=$auth_uuid, ecn=true, skip-cert-verify=${skip_cert}, sni=$tuic_domain
EOF

  cat << EOF > "$STATE_FILE"
port='${main_p}'
auth_uuid='${auth_uuid}'
auth_pwd='${auth_pwd}'
tuic_domain='${tuic_domain}'
cert_path='${cert_path}'
key_path='${key_path}'
EOF
  chmod 600 "$STATE_FILE"

  rc-service "$SB_SERVICE_NAME" restart >/dev/null 2>&1 || true
  if rc-service "$SB_SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
    info "sing-box TUIC 服务配置并启动成功！"
  else
    if pgrep -f "$BINARY_PATH run" >/dev/null 2>&1; then
      info "服务已在常驻后台进程状态下建立成功！"
    else
      error "sing-box TUIC 启动失败，可在菜单中按 8 查看详细的错误日志。"
    fi
  fi
  showconf
}

write_openrc_script() {
  cat << EOF > "$OPENRC_SERVICE_PATH"
#!/sbin/openrc-run

name="${SB_SERVICE_NAME}"
description="sing-box TUIC OpenRC Standalone Service"
cfgfile="${TUIC_CONFIG}"
logfile="${LOG_FILE}"
command="${BINARY_PATH}"
command_args="run -c ${TUIC_CONFIG}"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "\$cfgfile" ]; then
        eerror "Configuration file \$cfgfile missing!"
        return 1
    fi
    
    # 每次通过底层守护组件加载服务前，对系统级网络转发、重定向模块执行强行自愈拉起
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    modprobe iptable_nat >/dev/null 2>&1 || true
    modprobe xt_REDIRECT >/dev/null 2>&1 || true
    
    if [ -f "/etc/sing-box-tuic/hopping.txt" ] && [ -f "/etc/sing-box-tuic/main_port.txt" ]; then
        local hop_val=\$(cat "/etc/sing-box-tuic/hopping.txt")
        local main_p=\$(cat "/etc/sing-box-tuic/main_port.txt")
        local start_p=\${hop_val%-*}
        local end_p=\${hop_val#*-}
        iptables -t nat -D PREROUTING -p udp --dport "\$start_p:\$end_p" -j REDIRECT --to-ports "\$main_p" 2>/dev/null || true
        iptables -t nat -A PREROUTING -p udp --dport "\$start_p:\$end_p" -j REDIRECT --to-ports "\$main_p"
        ip6tables -t nat -A PREROUTING -p udp --dport "\$start_p:\$end_p" -j REDIRECT --to-ports "\$main_p" 2>/dev/null || true
    fi

    touch "\$logfile"
    chown singbox:singbox "\$logfile"
    chmod 644 "\$logfile"
    
    command_background="yes"
    pidfile="/run/\${RC_SVCNAME}.pid"
    output_log="\$logfile"
    error_log="\$logfile"
    
    local port
    port=\$(jq -r '.inbounds[0].listen_port // 0' "\$cfgfile" 2>/dev/null)
    if [ "\$port" -lt 1024 ] && [ "\$port" -ne 0 ]; then
        command_user="root:root"
    else
        command_user="singbox:singbox"
    fi
}
EOF
  chmod +x "$OPENRC_SERVICE_PATH"
  rc-update add "$SB_SERVICE_NAME" default >/dev/null 2>&1 || true
}

download_core() {
  local arch url
  arch=$(detect_arch)
  get_latest_version
  url=$(printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' "$SINGBOX_VERSION" "$SINGBOX_VERSION" "$arch")
  
  info "正在下载官方核心 sing-box v$SINGBOX_VERSION..."
  cd "$TMP_DIR"
  if ! wget -O sing-box.tar.gz -q "$url"; then
    curl -fsSL -o sing-box.tar.gz "$url" || { error "下载核心文件失败"; return 1; }
  fi
  
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  rc-service "$SB_SERVICE_NAME" stop >/dev/null 2>&1 || true
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box TUIC 专属内核释放完毕。"
  return 0
}

install_tuic() {
  echo -e "${GREEN}[信息] 开始在 Alpine 下部署独立、抗误杀式 sing-box TUIC V5 面板...${RESET}"
  check_environment
  mkdir -p "$CONFIG_DIR" "$TUIC_DIR"

  if ! download_core; then return 1; fi

  write_openrc_script
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
    error "当前系统未检测到独立内核，无法执行原地升级。"
    return 1
  fi
  info "正在执行专属内核原地无损覆盖升级..."
  if download_core; then
    rc-service "$SB_SERVICE_NAME" start >/dev/null 2>&1 || true
    info "sing-box TUIC 内核纯净原地升级成功！"
  else
    error "核心升级遭遇未预期中断。"
  fi
}

unsttuic() {
  warn "即将清除端口规则并安全卸载 sing-box TUIC v5 服务..."
  if [[ -f "${CONFIG_DIR}/hopping.txt" && -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    local main_p=$(cat "${CONFIG_DIR}/main_port.txt")
    manage_udp_jump "remove" "$start_p" "$end_p" "$main_p"
  fi

  rc-service "$SB_SERVICE_NAME" stop >/dev/null 2>&1 || true
  rc-update del "$SB_SERVICE_NAME" default >/dev/null 2>&1 || true
  pkill -f "$BINARY_PATH run" || true
  
  rm -f "$BINARY_PATH" "$OPENRC_SERVICE_PATH" "$LOG_FILE" "$STATE_FILE"
  rm -rf "$CONFIG_DIR" "$TUIC_DIR"
  
  info "完全卸载完成，清理完毕！"
}

changeconf() {
  if [[ ! -f "$TUIC_CONFIG" ]]; then
    error "配置文件不存在，请先选择选项 1 安装独立服务"
    return 1
  fi

  local old_uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$TUIC_CONFIG")
  local old_pwd=$(jq -r '.inbounds[0].users[0].password // empty' "$TUIC_CONFIG")
  local old_cert=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$TUIC_CONFIG")
  local old_key=$(jq -r '.inbounds[0].tls.key_path // empty' "$TUIC_CONFIG")
  local old_sni=$(jq -r '.inbounds[0].tls.server_name // "www.bing.com"' "$TUIC_CONFIG")

  clear
  echo -e "${GREEN}====== 修改 sing-box Tuic 配置 ======${RESET}"
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
  info "配置参数与自愈防火墙链条重构刷新成功！"
}

showconf() {
  if [[ ! -d "$TUIC_DIR" ]]; then
    error "未找到分享配置文件。"
    return
  fi
  echo -e "${GREEN}====== 节点分享与配置信息 ======${RESET}"
  cat "$TUIC_DIR/url.txt"
  echo
}

menu() {
  check_environment
  while true; do
    clear
    local raw_status=$(get_tuic_status)
    local status=""
    if [[ "$raw_status" == "RUNNING" ]]; then
      status="${GREEN}● 运行中${RESET}"
    else
      status="${RED}● 未运行${RESET}"
    fi

    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Sing-box(Tuicv5) 隔离独立面板 ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status}"
    echo -e "${GREEN}version :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}Port   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 隔离自愈型 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}2. 更新 隔离自愈型 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}3. 卸载 隔离自愈型 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}4. 修改隔离配置${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}8. 查看专属闪退与系统日志${RESET}"
    echo -e "${GREEN}9. 查看节点分享配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_tuic; pause ;;
      2) update_tuic; pause ;;
      3) unsttuic; pause ;;
      4) changeconf; pause ;;
      5) rc-service "$SB_SERVICE_NAME" start || pkill -f "$BINARY_PATH run" || true; info "服务已成功启动。"; pause ;;
      6) rc-service "$SB_SERVICE_NAME" stop || pkill -f "$BINARY_PATH run" || true; info "服务已成功停止。"; pause ;;
      7) rc-service "$SB_SERVICE_NAME" restart || true; info "服务与防火墙规则已重启刷新。"; pause ;;
      8) if [[ -f "$LOG_FILE" ]]; then tail -n 50 "$LOG_FILE"; else warn "未发现运行日志文件，请检查服务是否从未启动成功。"; fi; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

if [[ ${EUID} -ne 0 ]]; then
  error "请切换至 root 用户运行此面板脚本。"
  exit 1
fi

menu "$@"
