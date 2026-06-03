#!/usr/bin/env bash
#
# Alpine sing-box AnyTLS 专属管理面板
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly BINARY_PATH="/usr/local/bin/sing-box-anytls"
readonly ANYTLS_CONFIG="/etc/sing-box-anytls/config.json"
readonly SB_DIR="/root/proxynode/anytls"
CONFIG_DIR="/etc/sing-box-anytls"
OPENRC_SERVICE_PATH="/etc/init.d/sing-box-anytls"
LOG_FILE="/var/log/sing-box-anytls.log"
RUN_USER="singbox-anytls"

TMP_DIR=$(mktemp -d -t sb-anytls.XXXXXX)

# 颜色标准规范
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
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
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools gcompat socat python3
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

get_latest_version() {
  info "正在从 GitHub 获取 sing-box 最新版本号..."
  local latest_v
  latest_v=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name | sed 's/^v//')
  
  if [[ -z "$latest_v" || "$latest_v" == "null" ]]; then
    warn "通过 API 获取最新版本失败，尝试备用匹配方案..."
    latest_v=$(curl -fsSL "https://github.com/SagerNet/sing-box/releases/latest" | grep -oE 'releases/tag/v[0-9.]+' | head -n1 | sed 's|releases/tag/v||')
  fi

  if [[ -n "$latest_v" ]]; then
    SINGBOX_VERSION="$latest_v"
    info "成功获取最新版本: v$SINGBOX_VERSION"
  else
    SINGBOX_VERSION="1.13.12"
    warn "无法获取最新版本，将使用保底版本: v$SINGBOX_VERSION"
  fi
}

# =========================================================
# 4. 网络诊断与配置管理辅助
# =========================================================
get_public_ip() {
    local ip_addr
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip_addr=$($cmd "$url" 2>/dev/null) && [[ -n "$ip_addr" ]] && echo "$ip_addr" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip_addr=$($cmd "$url" 2>/dev/null) && [[ -n "$ip_addr" ]] && echo "$ip_addr" && return
        done
    done
    echo "127.0.0.1"
}

check_port() {
  local port_chk="$1"
  if ss -tunlp | grep -E -q ":$port_chk "; then
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

get_anytls_status() {
  if rc-service sing-box-anytls status 2>/dev/null | grep -q "started"; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

get_current_port_display() {
  if [[ -f "$ANYTLS_CONFIG" ]]; then
    jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null || echo "-"
  else echo "-"; fi
}

# 修复外部自定义证书的穿透访问权限，确保非root运行的 singbox-anytls 用户有权读取
fix_external_cert_permission() {
  local cert="$1"
  local key="$2"
  
  # 针对 /root 目录的致命硬拦截
  if [[ "$cert" == /root/* ]] || [[ "$key" == /root/* ]]; then
    error "致命拒绝: 检测到您的证书位于 /root/ 目录下！"
    warn "原因分析: /root 目录权限极为严苛(700)，任何非root用户(包括 singbox-anytls)均无权穿透。"
    warn "         即使强行赋予文件 644 权限，内核也会因路径阻塞拒绝读取。"
    info "权威推荐: 请在 acme.sh 命令中加上 --install-cert 指令，将证书自动分发到公共目录"
    info "         (例如: /etc/sing-box-anytls/certs/ 或 /etc/ssl/ 文件夹下) 再试。"
    return 1
  fi

  # 1. 自动提取并【逐级向上】放行外部证书的所有上级目录
  info "正在为外部证书路径逐级赋予检索穿透权限 (+x) ..."
  local dir
  for file in "$cert" "$key"; do
    dir=$(dirname "$file")
    while [[ "$dir" != "/" && -n "$dir" ]]; do
      chmod o+x "$dir" 2>/dev/null || true
      
      # 3. 如果系统支持 ACL，精准安全地给 sing-box 账号加上特殊通行证
      if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:"$RUN_USER":rx "$dir" 2>/dev/null || true
      fi
      
      dir=$(dirname "$dir")
    done
  done
  
  # 2. 确保证书和密钥文件本身可读（私钥通常建议 640 或 644，为了降权用户读取，这里规范为 644 或配合 ACL）
  info "正在规范化外部证书与私钥文件的读取权限 ..."
  chmod 644 "$cert" 2>/dev/null || true
  chmod 644 "$key" 2>/dev/null || true
  
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:"$RUN_USER":r "$cert" "$key" 2>/dev/null || true
  fi
  
  return 0
}

# =========================================================
# 5. 面板节点配置生成核心逻辑 (AnyTLS)
# =========================================================
inst_cert() {
  mkdir -p "$CONFIG_DIR/certs"

  echo "---------------------------------------------"
  echo -e "AnyTLS 证书申请方式如下："
  echo -e " 1) 必应伪装自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme自动申请 (需放行 80 端口)"
  echo -e " 3) 自定义证书路径"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
  certInput=${certInput:-1}

  cert_path="$CONFIG_DIR/certs/cert.pem"
  key_path="$CONFIG_DIR/certs/key.pem"

  if [[ $certInput == 2 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。"
    fi

    if [[ -f "$cert_path" && -f "$key_path" && -s "$cert_path" && -s "$key_path" && -f "$CONFIG_DIR/certs/ca.log" ]]; then
      sb_domain=$(cat "$CONFIG_DIR/certs/ca.log")
      info "检测到已有域名 [${sb_domain}] 的安全区证书，正在复用..."
    else
      read -rp "请输入需要申请证书的域名: " domain
      [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
      
      info "正在检查并安装 Acme.sh 依赖..."
      local acme_cmd="/root/.acme.sh/acme.sh"
      if [[ ! -f "$acme_cmd" ]]; then
        curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
      fi
      
      "$acme_cmd" --set-default-ca --server letsencrypt
      
      info "正在向 Let's Encrypt 申请证书..."
      if [[ "$(get_public_ip)" =~ ":" ]]; then
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
      else
        "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
      fi
      
      # =========================================================
      # 【智能状态探针】纯 OpenRC 架构：有配置(续期)则重启，无配置(初装)则静默
      # =========================================================
      local reload_cmd="[ -f /etc/sing-box-anytls/config.json ] && /sbin/rc-service sing-box-anytls restart || echo '[信息] 初次部署，跳过服务同步'"

      if "$acme_cmd" --install-cert -d "${domain}" \
        --key-file "$key_path" \
        --fullchain-file "$cert_path" \
        --ecc \
        --reloadcmd "$reload_cmd"; then
        echo "$domain" > "$CONFIG_DIR/certs/ca.log"
        sb_domain=$domain
        info "Acme 专属伪装证书申请并成功分发（已配置自动续签重启机制）！"
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
      read -rp "请输入证书对应的域名: " sb_domain
      
      if [[ -f "$user_cert" && -f "$user_key" ]]; then
        rm -f "$cert_path" "$key_path"
        
        # 建立软链接之前，先修复外部文件和目录的穿透访问权限
        fix_external_cert_permission "$user_cert" "$user_key"

        ln -sf "$user_cert" "$cert_path"
        ln -sf "$user_key" "$key_path"
        info "自定义证书已成功通过软链接同步至内部安全区。"
        break
      else
        error "找不到输入的证书文件，请重新输入。"
        echo "---------------------------------------------"
      fi
    done
  fi

  if [[ $certInput == 1 ]]; then
    info "将使用必应自签证书作为 AnyTLS 外壳的节点证书"
    rm -f "$cert_path" "$key_path"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    sb_domain="www.bing.com"
    
    chmod 644 "$cert_path" || true
    chmod 600 "$key_path" || true
  fi

  # 规范所有权：使用 -h 规避穿透修改外部真实证书所有权
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"
  chown -h ${RUN_USER}:${RUN_USER} "$cert_path" "$key_path" 2>/dev/null || true
}

inst_port() {
  local default_port=""
  if [[ -f "$ANYTLS_CONFIG" ]]; then
    default_port=$(jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null)
  fi

  local prompt_msg="设置 AnyTLS 服务端监听主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 AnyTLS 服务端监听主端口 [当前: ${default_port}, 回车不修改]: "

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
  local url_ip
  url_ip=$(get_public_ip)

  # 1. 写入服务端隔离配置文件 (anytls 协议入站)
  cat << EOF > "$ANYTLS_CONFIG"
{
  "log": {
    "level": "info",
    "output": "$LOG_FILE",
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
          "password": "$auth_pwd"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sb_domain",
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

  chmod 640 "$ANYTLS_CONFIG"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"
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

  rc-service sing-box-anytls restart
  if rc-service sing-box-anytls status | grep -q "started"; then
    info "sing-box AnyTLS 服务运行环境安全就绪！"
  else
    error "核心服务启动失败，请进入菜单 8 查看隔离日志。"
  fi
  showconf
}

# =========================================================
# 6. 安装、更新与卸载核心流控
# =========================================================
write_openrc_script() {
  cat << 'EOF' > "$OPENRC_SERVICE_PATH"
#!/sbin/openrc-run

name="sing-box-anytls"
description="sing-box AnyTLS OpenRC Isolated Service"
cfgfile="/etc/sing-box-anytls/config.json"
logfile="/var/log/sing-box-anytls.log"
command="/usr/local/bin/sing-box-anytls"
command_args="run -c /etc/sing-box-anytls/config.json"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "$cfgfile" ]; then
        eerror "Configuration file $cfgfile missing!"
        return 1
    fi
    
    touch "$logfile"
    chown singbox-anytls:singbox-anytls "$logfile"
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
        command_user="singbox-anytls:singbox-anytls"
    fi
}
EOF
  chmod +x "$OPENRC_SERVICE_PATH"
  rc-update add sing-box-anytls default >/dev/null 2>&1 || true
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
  local extracted
  extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  rc-service sing-box-anytls stop >/dev/null 2>&1 || true
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box-anytls 核心释放完毕。"
  return 0
}

install_anytls() {
  echo -e "${GREEN}[信息] 开始在 Alpine 下部署专属隔离的 sing-box AnyTLS 环境 ...${RESET}"
  check_environment
  mkdir -p "$CONFIG_DIR" "$SB_DIR"

  if ! download_core; then return 1; fi

  write_openrc_script

  inst_cert || return 1
  inst_port
  
  read -rp "设置 AnyTLS 密码 (回车自动分配高强随机字符串): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_anytls() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未检测到核心，无法执行覆盖升级。"
    return 1
  fi
  info "检测到已有环境，正在执行纯净原地覆盖核心升级..."
  if download_core; then
    rc-service sing-box-anytls start
    info "sing-box-anytls 核心纯净升级覆盖成功，服务已安全启动！"
  else
    error "核心升级遭遇未预期中断。"
  fi
}

unstanytls() {
  warn "即将执行全面清洁卸载..."

  rc-service sing-box-anytls stop || true
  rc-update del sing-box-anytls default >/dev/null 2>&1 || true
  
  rm -f "$BINARY_PATH" "$OPENRC_SERVICE_PATH" "$LOG_FILE"
  rm -rf "$CONFIG_DIR" "$SB_DIR"
  
  info "AnyTLS 专属隔离服务及相关配置已被彻底清洁卸载！"
}

changeconf() {
  if [[ ! -f "$ANYTLS_CONFIG" ]]; then
    error "配置文件不存在，请先选择选项 1 安装"
    return 1
  fi

  local old_pwd old_cert old_key old_sni
  old_pwd=$(jq -r '.inbounds[0].users[0].password // empty' "$ANYTLS_CONFIG")
  old_cert=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$ANYTLS_CONFIG")
  old_key=$(jq -r '.inbounds[0].tls.key_path // empty' "$ANYTLS_CONFIG")
  old_sni=$(jq -r '.inbounds[0].tls.server_name // "www.bing.com"' "$ANYTLS_CONFIG")

  clear
  echo -e "${GREEN}====== 修改 AnyTLS 专属配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port 

  local auth_pwd
  read -rp "设置 AnyTLS 验证密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local cert_path key_path sb_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改伪装层证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    sb_domain="$old_sni"
  fi

  write_and_show_config
  info "配置与客户端备份刷新修改成功！"
}

# =========================================================
# 核心业务重构：精准嵌入最新的动态提取与对齐展示函数
# =========================================================
showconf() {
  if [[ ! -f "$ANYTLS_CONFIG" ]]; then
    error "未发现核心配置文件，请先选择选项 1 安装。"
    return
  fi

  # 实时从服务端核心配置中提取参数，确保 100% 准确
  local hostname=$(hostname -s | sed 's/ /_/g')
  local main_port=$(jq -r '.inbounds[0].listen_port' "$ANYTLS_CONFIG" 2>/dev/null || echo "18055")
  local auth_pwd=$(jq -r '.inbounds[0].users[0].password' "$ANYTLS_CONFIG" 2>/dev/null || echo "密码")
  local sb_domain=$(jq -r '.inbounds[0].tls.server_name' "$ANYTLS_CONFIG" 2>/dev/null || echo "anyoo.vfz.dpdns.org")
  
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
  echo -e "${YELLOW}IP       : ${ip}${RESET}"
  echo -e "${YELLOW}端口     : ${main_port}${RESET}"
  echo -e "${YELLOW}密码     : ${auth_pwd}${RESET}"
  echo -e "${YELLOW}伪装 SNI : ${sb_domain}${RESET}"
  echo -e "${GREEN}---------------------------${RESET}"
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo -e "${YELLOW}[信息] V2rayN 链接：${RESET}"
  echo -e "${YELLOW}anytls://${auth_pwd}@${url_ip}:${main_port}?security=tls&sni=${sb_domain}&insecure=${is_insecure}&allowInsecure=${is_insecure}&type=tcp&headerType=none#${hostname}-Anytls${RESET}"
  echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
  echo -e "${YELLOW}${hostname}-Anytls = anytls, ${url_ip}, ${main_port}, password=${auth_pwd}, sni=${sb_domain}, tfo=true, skip-cert-verify=${skip_cert}, reuse=false${RESET}"
  echo -e "${YELLOW}---------------------------------${RESET}"
  
}

# =========================================================
# 7. 面板交互菜单 
# =========================================================
menu() {
  while true; do
    clear
    local raw_status status version port_show
    raw_status=$(get_anytls_status)
    status=""
    if [[ "$raw_status" == "RUNNING" ]]; then
      status="${GREEN}● 运行中${RESET}"
    else
      status="${RED}● 未运行${RESET}"
    fi

    version=$(get_installed_version)
    port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Sing-box AnyTLS 面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status}"
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
      1) install_anytls; pause ;;
      2) update_anytls; pause ;;
      3) unstanytls; pause ;;
      4) changeconf; pause ;;
      5) rc-service sing-box-anytls start && info "服务已成功启动！"; pause ;;
      6) rc-service sing-box-anytls stop && info "服务已成功停止！"; pause ;;
      7) rc-service sing-box-anytls restart && info "服务已成功重启！"; pause ;;
      8) if [[ -f "$LOG_FILE" ]]; then tail -n 50 "$LOG_FILE"; else warn "未发现运行日志文件。"; fi; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择. "; sleep 1 ;;
    esac
  done
}

if [[ ${EUID} -ne 0 ]]; then
  error "请切换至 root 用户运行此面板脚本。"
  exit 1
fi

menu "$@"
