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
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools
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
    SINGBOX_VERSION="1.12.0"
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
    echo "无法获取公网IP"
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

# =========================================================
# 5. 面板节点配置生成核心逻辑 (AnyTLS)
# =========================================================
inst_cert() {
  mkdir -p "$CONFIG_DIR/certs"

  echo "---------------------------------------------"
  echo -e "AnyTLS 证书申请方式如下："
  echo -e " 1) 必应伪装自签证书 ${YELLOW}（默认）${RESET}"
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
      
      if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
        echo "$domain" > "$CONFIG_DIR/certs/ca.log"
        sb_domain=$domain
        info "Acme 专属伪装证书申请并成功分发！"
      else
        error "Acme 证书申请失败，自动切换回自签模式。"
        certInput=1
      fi
    fi
  elif [[ $certInput == 3 ]]; then
    local user_cert user_key
    read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
    read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
    read -rp "请输入证书对应的域名: " sb_domain
    
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
    info "将使用必应自签证书作为 AnyTLS 外壳的节点证书"
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    sb_domain="www.bing.com"
  fi

  chmod 644 "$cert_path"
  chmod 600 "$key_path"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR/certs"
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

  # 3. 将变量映射到客户端专用展示名，用于展示你给的代码块
  echo "$url_ip" > "$CONFIG_DIR/ip.txt"
  echo "$port" > "$CONFIG_DIR/port.txt"
  echo "$auth_pwd" > "$CONFIG_DIR/pwd.txt"
  echo "$sb_domain" > "$CONFIG_DIR/sni.txt"

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

showconf() {
  if [[ ! -f "$SB_DIR/sb-client.json" ]]; then
    error "未找到导出的分享配置文件。"
    return
  fi

  # 读取缓存的映射变量进行回显打印
  local ip port_num pwd_str hostname
  ip=$(cat "$CONFIG_DIR/ip.txt" 2>/dev/null || echo "127.0.0.1")
  port_num=$(cat "$CONFIG_DIR/port.txt" 2>/dev/null || echo "443")
  pwd_str=$(cat "$CONFIG_DIR/pwd.txt" 2>/dev/null || echo "password")
  hostname=$(hostname -s | sed 's/ /_/g')

  # =========================================================
  # 完美嵌入并输出你提供的节点回显逻辑
  # =========================================================
  echo -e "${GREEN}====== AnyTLS 节点信息 ======${RESET}"
  echo -e "${YELLOW}IP      : ${ip}${RESET}"
  echo -e "${YELLOW}端口    : ${port_num}${RESET}"
  echo -e "${YELLOW}密码    : ${pwd_str}${RESET}"
  echo -e "${GREEN}---------------------------${RESET}"
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo -e "${YELLOW}[信息] V2rayN 链接：${RESET}"
  echo -e "${CYAN}anytls://${pwd_str}@${ip}:${port_num}/?insecure=1#${hostname}-Anytls${RESET}"
  echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
  echo -e "${CYAN}${hostname}-Anytls = anytls, ${ip}, ${port_num}, password=${pwd_str}, tfo=true, skip-cert-verify=true, reuse=false${RESET}"
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
    echo -e "${GREEN}      Sing-box AnyTLS 面板       ${RESET}"
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
    echo -e "${GREEN}9. 查看节点及链接配置${RESET}"
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
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

if [[ ${EUID} -ne 0 ]]; then
  error "请切换至 root 用户运行此面板脚本。"
  exit 1
fi

menu "$@"
