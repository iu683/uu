#!/usr/bin/env bash
#
# sing-box Hysteria 2 [Alpine专属]
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly BINARY_PATH="/usr/local/bin/sing-box-hy2"
readonly HY2_CONFIG="/etc/sing-box-hy2/config.json"
readonly HY2_DIR="/root/proxynode/hy2"
CONFIG_DIR="/etc/sing-box-hy2"
OPENRC_SERVICE_PATH="/etc/init.d/sing-box-hy2"
LOG_FILE="/var/log/sing-box-hy2.log"
RUN_USER="singbox-hy2"

TMP_DIR=$(mktemp -d -t sb-hy2.XXXXXX)

# 颜色标准规范
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# GITHUB 代理列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

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
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools iptables ip6tables gcompat socat python3
  
  if [[ -f /etc/init.d/iptables ]]; then
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-service iptables start >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/init.d/ip6tables ]]; then
    rc-update add ip6tables default >/dev/null 2>&1 || true
    rc-service ip6tables start >/dev/null 2>&1 || true
  fi
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

check_environment() {
  if ! is_alpine; then
    error "本脚本仅支持 Alpine Linux 系统。"
    exit 95
  fi
  install_packages
  create_user
}

get_installed_version() {
  if [[ -f "$BINARY_PATH" ]]; then
    "$BINARY_PATH" version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知版本"
  else
    echo "未安装"
  fi
}

# =========================================================
# 代理网络请求辅助函数
# =========================================================
request_github_api() {
  local path="$1"
  local response=""
  
  for proxy in "${GITHUB_PROXY[@]}"; do
    # API 请求不能直接加代理前缀，需要判断是否为直连，或者利用特定的 API 代理
    # 如果是直连（proxy为空），或者由于 API 的特殊性，这里优先尝试直接请求 GitHub API
    # 如果直连失败，再尝试通过代理（部分代理支持 API 转发，部分不支持）
    if [[ -z "$proxy" ]]; then
      response=$(curl -fsSL --max-time 8 "https://api.github.com/${path}")
    else
      # 很多 gh-proxy 不支持 api.github.com 转发，但可以用 raw/普通链接规则试探
      response=$(curl -fsSL --max-time 8 "${proxy}https://api.github.com/${path}" 2>/dev/null || true)
    fi
    
    if [[ -n "$response" && "$response" != "null" ]]; then
      echo "$response"
      return 0
    fi
  done
  return 1
}

get_latest_version() {
  info "正在从 GitHub 获取 sing-box 最新版本号..."
  local latest_v=""
  
  # 优先尝试 API 获取
  local api_res
  if api_res=$(request_github_api "repos/SagerNet/sing-box/releases/latest"); then
    latest_v=$(echo "$api_res" | jq -r .tag_name 2>/dev/null | sed 's/^v//')
  fi
  
  # 如果 API 失败，轮询代理网页端匹配
  if [[ -z "$latest_v" || "$latest_v" == "null" ]]; then
    warn "通过 API 获取最新版本失败，尝试备用网页匹配方案..."
    for proxy in "${GITHUB_PROXY[@]}"; do
      latest_v=$(curl -fsSL --max-time 8 "${proxy}https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oE 'releases/tag/v[0-9.]+' | head -n1 | sed 's|releases/tag/v||' || true)
      if [[ -n "$latest_v" ]]; then
        break
      fi
    done
  fi

  if [[ -n "$latest_v" ]]; then
    SINGBOX_VERSION="$latest_v"
    info "成功获取最新版本: v$SINGBOX_VERSION"
  else
    SINGBOX_VERSION="1.13.12"
    warn "无法获取最新版本，将使用保底版本: v$SINGBOX_VERSION"
  fi
}

clear_old_iptables() {
  if [[ -f "${CONFIG_DIR}/hopping.txt" && -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local old_hop
    old_hop=$(cat "${CONFIG_DIR}/hopping.txt")
    local old_port
    old_port=$(cat "${CONFIG_DIR}/main_port.txt")
    local old_start="${old_hop%-*}"
    local old_end="${old_hop#*-}"

    if [[ -n "$old_start" && -n "$old_end" && -n "$old_port" ]]; then
      info "正在清洁防火墙残留规则..."
      iptables -t nat -D PREROUTING -p udp -m multiport --dports "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      ip6tables -t nat -D PREROUTING -p udp -m multiport --dports "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      iptables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      ip6tables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
    fi
  fi
}

apply_new_iptables() {
  clear_old_iptables
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val
    hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p="${hop_val%-*}"
    local end_p="${hop_val#*-}"
    
    info "正在应用 iptables 转发规则: UDP $start_p-$end_p => 主端口 $port"
    if iptables -t nat -A PREROUTING -p udp -m multiport --dports "$start_p:$end_p" -j REDIRECT --to-ports "$port"; then
      ip6tables -t nat -A PREROUTING -p udp -m multiport --dports "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    else
      iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port"
      ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    fi
    
    echo "$port" > "${CONFIG_DIR}/main_port.txt"
    
    if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
    if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi
    info "防火墙端口跳跃规则已固化。"
  fi
}

# =========================================================
# 4. 网络诊断与配置管理辅助
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
    echo "无法获取公网IP"
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

get_hy2_status() {
  if rc-service sing-box-hy2 status 2>/dev/null | grep -q "started"; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

get_current_port_display() {
  if [[ -f "$HY2_CONFIG" ]]; then
    local main_port jump_range="无"
    main_port=$(jq -r '.inbounds[0].listen_port // empty' "$HY2_CONFIG" 2>/dev/null)
    [[ -f "${CONFIG_DIR}/hopping.txt" ]] && jump_range=$(cat "${CONFIG_DIR}/hopping.txt")
    
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "-"; fi
}

# =========================================================
# 5. 面板节点配置生成核心逻辑 (Hysteria 2)
# =========================================================

fix_external_cert_permission() {
  local cert="$1"
  local key="$2"
  
  if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
    error "致命拒绝: 检测到您的证书位于 /root/ 目录下！"
    warn "原因分析: /root 目录权限极为严苛(700)，任何非 root 用户(包括 singbox-hy2)均无权穿透。"
    warn "          即使强行赋予文件 644 权限，内核也会因路径阻塞拒绝读取。"
    info "权威推荐: 请在 acme.sh 命令中加上 --install-cert 指令，将证书自动分发到公共目录"
    info "          (例如: /etc/sing-box-hy2/certs/ 或 /etc/ssl/ 文件夹下) 再试。"
    return 1
  fi

  info "正在为外部证书路径逐级赋予检索穿透权限 (+x) ..."
  local dir
  for file in "$cert" "$key"; do
    dir=$(dirname "$file")
    while [[ "$dir" != "/" && -n "$dir" ]]; do
      chmod o+x "$dir" 2>/dev/null || true
      if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:"$RUN_USER":rx "$dir" 2>/dev/null || true
      fi
      dir=$(dirname "$dir")
    done
  done
  
  info "正在规范化外部证书与私钥文件的读取权限 ..."
  chmod 644 "$cert" 2>/dev/null || true
  chmod 644 "$key" 2>/dev/null || true
  
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:"$RUN_USER":r "$cert" "$key" 2>/dev/null || true
  fi
  return 0
}

inst_cert() {
  mkdir -p "$CONFIG_DIR/certs"

  echo "---------------------------------------------"
  echo -e "Hysteria 2 协议证书申请方式如下："
  echo -e " 1) 必应自签证书${YELLOW}（默认）${RESET} "
  echo -e " 2) Acme自动申请(需放行80端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签证书): " certInput
  certInput=${certInput:-1}

  cert_path="$CONFIG_DIR/certs/cert.pem"
  key_path="$CONFIG_DIR/certs/key.pem"

  if [[ $certInput == 2 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。"
    fi

    if [[ -f "$cert_path" && -f "$key_path" && -s "$cert_path" && -s "$key_path" && -f "$CONFIG_DIR/certs/ca.log" ]]; then
      hy2_domain=$(cat "$CONFIG_DIR/certs/ca.log")
      info "检测到已有域名 [${hy2_domain}] 的安全区证书，正在复用..."
    else
      read -rp "请输入需要申请证书的域名: " domain
      [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
      
      info "正在检查并安装 Acme.sh 依赖..."
      local acme_cmd="/root/.acme.sh/acme.sh"
      if [[ ! -f "$acme_cmd" ]]; then
        # Acme.sh 安装同样加入了代理尝试
        local acme_installed=false
        for proxy in "${GITHUB_PROXY[@]}"; do
          info "正在尝试通过代理 ${proxy:-直连} 下载 acme.sh..."
          if curl -fsSL --max-time 15 "${proxy}https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com; then
            acme_installed=true
            break
          fi
        done
        if [[ "$acme_installed" = false ]]; then
           error "Acme.sh 安装失败，请检查网络。"
           return 1
        fi
      fi
      
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      info "正在向 Let's Encrypt 申请证书..."
      if [[ "$(get_public_ip)" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      
      local reload_cmd="[ -f /etc/sing-box-hy2/config.json ] && /sbin/rc-service sing-box-hy2 restart || echo '[信息] 初次部署，跳过服务同步'"
      
      if "$acme_cmd" --install-cert -d "${domain}" \
        --key-file "$key_path" \
        --fullchain-file "$cert_path" \
        --ecc \
        --reloadcmd "$reload_cmd"; then
        echo "$domain" > "$CONFIG_DIR/certs/ca.log"
        hy2_domain=$domain
        info "Acme 证书申请并成功分发！"
      else
        error "Acme 证书申请失败，自动切换回自签模式。"
        certInput=1
      fi
    fi
  elif [[ $certInput == 3 ]]; then
    while true; do
      local user_cert user_key
      read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
      read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
      read -rp "请输入证书对应的域名: " hy2_domain
      
      if [[ -f "$user_cert" && -f "$user_key" ]]; then
        rm -f "$cert_path" "$key_path"
        
        if fix_external_cert_permission "$user_cert" "$user_key"; then
          ln -sf "$user_cert" "$cert_path"
          ln -sf "$user_key" "$key_path"
          info "自定义外部证书已通过安全软链接无缝同步。"
          break
        else
          return 1
        fi
      else
        error "找不到输入的证书文件，请重新确认路径。"
        echo "---------------------------------------------"
      fi
    done
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 Hysteria 2 外壳的节点证书"
    rm -f "$cert_path" "$key_path"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    hy2_domain="www.bing.com"
    
    chmod 644 "$cert_path" || true
    chmod 600 "$key_path" || true
  fi

  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"
  chown -h ${RUN_USER}:${RUN_USER} "$cert_path" "$key_path" 2>/dev/null || true
}

inst_port() {
  local default_port=""
  if [[ -f "$HY2_CONFIG" ]]; then
    default_port=$(jq -r '.inbounds[0].listen_port // empty' "$HY2_CONFIG" 2>/dev/null)
  fi

  local prompt_msg="设置 Hysteria 2 服务端监听主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 Hysteria 2 服务端监听主端口 [当前: ${default_port}, 回车不修改]: "

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

  local default_hop=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    default_hop=$(cat "${CONFIG_DIR}/hopping.txt")
  fi

  echo "---------------------------------------------"
  if [[ -n "$default_hop" ]]; then
    echo -e "Hysteria 2 端口群使用模式 [当前已启用跳跃: ${default_hop}]："
  else
    echo -e "Hysteria 2 端口群使用模式 ："
  fi
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  
  local jumpInput
  read -rp "请选择端口模式 [1-2] (直接回车默认不变或选择默认项): " jumpInput
  
  if [[ -z "$jumpInput" && -n "$default_hop" ]]; then
    info "检测到回车确认，将 100% 保持原有端口跳跃配置 [${default_hop}] 保持不变。"
    echo "$port" > "${CONFIG_DIR}/main_port.txt"
    return 0
  fi

  jumpInput=${jumpInput:-2}
  clear_old_iptables

  if [[ $jumpInput == 2 ]]; then
    local old_start="" old_end=""
    if [[ -n "$default_hop" ]]; then
      old_start="${default_hop%-*}"
      old_end="${default_hop#*-}"
    fi

    while true; do
      local start_prompt="设置外部跳跃起始端口 (建议10000-65535)"
      [[ -n "$old_start" ]] && start_prompt="设置外部跳跃起始端口 [当前: ${old_start}, 回车不修改]"
      read -rp "${start_prompt}: " firstport
      firstport=${firstport:-$old_start}

      local end_prompt="设置外部跳跃末尾端口 (必须大于起始端口)"
      [[ -n "$old_end" ]] && end_prompt="设置外部跳跃末尾端口 [当前: ${old_end}, 回车不修改]"
      read -rp "${end_prompt}: " endport
      endport=${endport:-$old_end}

      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then 
        break
      else 
        error "输入无效！起始端口必须小于末尾端口，且范围在 1-65535 之间，请重新输入。"; 
      fi
    done
    echo "$firstport-$endport" > "${CONFIG_DIR}/hopping.txt"
  else
    rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt"
    info "已成功切换回单端口纯净模式"
    if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
    if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi
  fi
}

write_and_show_config() {
  local HOSTNAME
  HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip
  vps_ip=$(get_public_ip)
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  local is_insecure="0"
  local skip_cert="false"
  if [[ "$hy2_domain" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

  cat << EOF > "$HY2_CONFIG"
{
  "log": {
    "level": "info",
    "output": "$LOG_FILE",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "password": "$auth_pwd"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "server_name": "$hy2_domain",
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

  chmod 640 "$HY2_CONFIG"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"

  apply_new_iptables
  mkdir -p "$HY2_DIR"
  
  local final_port="$port"
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    final_port=$(cat "${CONFIG_DIR}/hopping.txt")
  fi

  cat << EOF > "$HY2_DIR/url.txt"
V6VPS 请自行替换 IP 地址为 V6
V2rayN 链接:
hysteria2://$auth_pwd@$last_ip:$port?sni=$hy2_domain&insecure=${is_insecure}#$HOSTNAME-hy2

Surge 配置:
$HOSTNAME-hy2 = hysteria2, $last_ip, $port, password=$auth_pwd, skip-cert-verify=true, sni=$hy2_domain
EOF

  rc-service sing-box-hy2 restart
  if rc-service sing-box-hy2 status | grep -q "started"; then
    info "sing-box Hysteria 2 服务配置并启动成功！"
  else
    error "sing-box-hy2 启动失败，可在菜单中按 8 查看详细的闪退日志。"
  fi
  showconf
}

# =========================================================
# 6. 安装、更新与卸载核心流控
# =========================================================
write_openrc_script() {
  cat << 'EOF' > "$OPENRC_SERVICE_PATH"
#!/sbin/openrc-run

name="sing-box-hy2"
description="sing-box Hysteria 2 OpenRC Isolated Service"
cfgfile="/etc/sing-box-hy2/config.json"
logfile="/var/log/sing-box-hy2.log"
command="/usr/local/bin/sing-box-hy2"
command_args="run -c /etc/sing-box-hy2/config.json"

depend() {
    need net
    after iptables ip6tables firewall
}

start_pre() {
    if [ ! -f "$cfgfile" ]; then
        eerror "Configuration file $cfgfile missing!"
        return 1
    fi
    
    touch "$logfile"
    chown singbox-hy2:singbox-hy2 "$logfile"
    chmod 644 "$logfile"
    
    command_background="yes"
    pidfile="/run/${RC_SVCNAME}.pid"
    
    output_log="$logfile"
    error_log="$logfile"
    
    local port
    port=$(jq -r '.inbounds[0].listen_port // 0' "$cfgfile" 2>/dev/null)
    if [ "$port" -lt 1024 ] && [ "$port" -ne 0 ]; then
        command_user="root:root"
    else
        command_user="singbox-hy2:singbox-hy2"
    fi
}
EOF
  chmod +x "$OPENRC_SERVICE_PATH"
  rc-update add sing-box-hy2 default >/dev/null 2>&1 || true
}

download_core() {
  local arch url
  arch=$(detect_arch)
  get_latest_version
  
  # =========================================================
  # 核心下载轮询代理机制
  # =========================================================
  local download_success=false
  cd "$TMP_DIR"
  
  for proxy in "${GITHUB_PROXY[@]}"; do
    url=$(printf '%ssing-box-%s-linux-%s.tar.gz' "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/" "$SINGBOX_VERSION" "$arch")
    if [[ -n "$proxy" ]]; then
      url="${proxy}${url}"
    fi
    
    info "正在通过代理 [ ${proxy:-直连保底} ] 下载官方核心 sing-box v$SINGBOX_VERSION..."
    
    if wget -O sing-box.tar.gz -q "$url" || curl -fsSL -o sing-box.tar.gz "$url"; then
      if [[ -s sing-box.tar.gz ]]; then
        download_success=true
        break
      fi
    fi
    warn "当前代理下载失败，正在尝试下一个..."
  done

  if [[ "$download_success" = false ]]; then
    error "所有代理及直连通道均下载核心文件失败，请检查网络后重试。"
    return 1
  fi
  
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted
  extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  rc-service sing-box-hy2 stop >/dev/null 2>&1 || true
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box-hy2 核心释放完毕。"
  return 0
}

install_hy2() {
  echo -e "${GREEN}[信息] 开始在 Alpine 下部署专属隔离的 sing-box Hysteria 2 ...${RESET}"
  check_environment
  mkdir -p "$CONFIG_DIR" "$HY2_DIR"

  if ! download_core; then return 1; fi

  write_openrc_script

  inst_cert || return 1
  inst_port
  
  read -rp "设置 Hysteria 2 验证密码 (回车自动分配随机高强密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_hy2() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未检测 to 核心，无法执行覆盖升级。"
    return 1
  fi
  info "检测到已有环境，正在执行纯净原地覆盖核心升级..."
  if download_core; then
    rc-service sing-box-hy2 start
    info "sing-box-hy2 核心纯净升级覆盖成功，服务已安全启动！"
  else
    error "核心升级遭遇未预期中断。"
  fi
}

unsthy2() {
  warn "即将执行全面清洁卸载..."
  
  clear_old_iptables
  if [[ -f /etc/init.d/iptables ]]; then /etc/init.d/iptables save &>/dev/null || true; fi
  if [[ -f /etc/init.d/ip6tables ]]; then /etc/init.d/ip6tables save &>/dev/null || true; fi

  rc-service sing-box-hy2 stop || true
  rc-update del sing-box-hy2 default >/dev/null 2>&1 || true
  
  rm -f "$BINARY_PATH" "$OPENRC_SERVICE_PATH" "$LOG_FILE"
  rm -rf "$CONFIG_DIR" "$HY2_DIR"
  
  info "Hysteria 2 专属服务、节点配置及防火墙跳跃链条已彻底清除！"
}

changeconf() {
  if [[ ! -f "$HY2_CONFIG" ]]; then
    error "配置文件不存在，请先选择选项 1 安装"
    return 1
  fi

  local old_pwd old_cert old_key old_sni
  old_pwd=$(jq -r '.inbounds[0].users[0].password // empty' "$HY2_CONFIG")
  old_cert=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$HY2_CONFIG")
  old_key=$(jq -r '.inbounds[0].tls.key_path // empty' "$HY2_CONFIG")
  old_sni=$(jq -r '.inbounds[0].tls.server_name // "www.bing.com"' "$HY2_CONFIG")

  clear
  echo -e "${GREEN}====== 修改 sing-box Hysteria 2 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port 

  local auth_pwd
  read -rp "设置 Hysteria 2 验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local cert_path key_path hy2_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    hy2_domain="$old_sni"
  fi

  write_and_show_config
  info "配置与转发链条刷新修改成功！"
}

showconf() {
  if [[ ! -d "$HY2_DIR" ]]; then
    error "未找到分享配置文件。"
    return
  fi
  echo -e "${GREEN}====== Hysteria 2 节点分享与配置信息 ======${RESET}"
  cat "$HY2_DIR/url.txt"
  echo
}

# =========================================================
# 7. 面板交互菜单 
# =========================================================
menu() {
  while true; do
    clear
    local raw_status
    raw_status=$(get_hy2_status)
    local status=""
    if [[ "$raw_status" == "RUNNING" ]]; then
      status="${YELLOW}● 运行中${RESET}"
    else
      status="${RED}● 未运行${RESET}"
    fi

    local version
    version=$(get_installed_version)
    local port_show
    port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     Sing-box Hysteria2 面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status}"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Sing-box Hysteria2${RESET}"
    echo -e "${GREEN}2. 更新 Sing-box${RESET}"
    echo -e "${GREEN}3. 卸载 Sing-box${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_hy2; pause ;;
      2) update_hy2; pause ;;
      3) unsthy2; pause ;;
      4) changeconf; pause ;;
      5) rc-service sing-box-hy2 start && info "服务已成功启动！"; pause ;;
      6) rc-service sing-box-hy2 stop && info "服务已成功停止！"; pause ;;
      7) rc-service sing-box-hy2 restart && info "服务已成功重启！"; pause ;;
      8) if [[ -f "$LOG_FILE" ]]; then tail -n 50 "$LOG_FILE"; else warn "未发现运行日志文件。"; fi; pause ;;
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
