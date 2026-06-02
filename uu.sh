#!/usr/bin/env bash
#
# sing-box (VLESS+WS+TLS) 核心控制面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly SB_CONFIG="/etc/singbox-vless-ws/config.json"
readonly SB_BINARY="/usr/local/bin/sing-box"
readonly SB_DIR="/root/proxynode/VlessWS"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/singbox-vless-ws"
REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
SINGBOX_USER="${SINGBOX_USER:-}"
SINGBOX_HOME_DIR="${SINGBOX_HOME_DIR:-}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 底层工具函数
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

generate_uuid() {
  if has_command uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    cat /dev/urandom | head -n 50 | md5sum | head -c 32 | sed -r 's/([0-9a-f]{8})([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{12})/\1-\2-\3-\4-\5/'
  fi
}

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

is_user_exists() { id "$1" > /dev/null 2>&1; }

check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  case "$(uname -m)" in
    'i386' | 'i686') ARCHITECTURE='386' ;;
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='armv7' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    's390x') ARCHITECTURE='s390x' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command openssl || install_software openssl
  has_command tar || install_software tar
  has_command socat || install_software socat
  has_command python3 || install_software python3
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null | head -n 1 || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases/latest" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '.tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  
  if [[ -n "$_tag_name" ]]; then
    echo "${_tag_name##*v}"
  else
    echo ""
  fi
}

download_singbox() {
  local _version="$1"
  local _destination="$2"
  local _download_url="$REPO_URL/releases/download/v${_version}/sing-box-${_version}-linux-${ARCHITECTURE}.tar.gz"
  
  info "正在下载官方 sing-box 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_singbox_server_service_base() {
  local _config_name="$1"
  cat << EOF
[Unit]
Description=sing-box Server Service (${_config_name}.json)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH run --config ${CONFIG_DIR}/${_config_name}.json
WorkingDirectory=$SINGBOX_HOME_DIR
User=$SINGBOX_USER
Group=$SINGBOX_USER
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 网络与配置扩展辅助函数
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
    error "无法获取公网 IP 地址。" && return 1
}

check_port() {
  local port="$1"
  if ss -tunlp 2>/dev/null | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
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

get_sb_status() {
  if has_command systemctl && systemctl is-active --quiet singbox-vless-ws 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$SB_CONFIG" ]]; then
    local main_port
    main_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "")
    echo "${main_port:- -}"
  else echo "-"; fi
}

restart_singbox_service() {
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable singbox-vless-ws >/dev/null 2>&1 || true
    systemctl restart singbox-vless-ws >/dev/null 2>&1 || true
    systemctl is-active --quiet singbox-vless-ws 2>/dev/null
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
    return 0
  fi
}

# =========================================================
# 4. 证书、端口交互、配置写入与自定义 Socks5 出口
# =========================================================
inst_cert() {
  mkdir -p /etc/singbox-vless-ws
  
  echo "---------------------------------------------"
  echo -e "sing-box TLS 证书申请方式如下："
  echo -e " 1) Acme 独立模式申请(需要开放 80 端口)${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme DNS API 自动申请 (无需放行80端口)"
  echo -e " 3) 自定义证书路径 (软链接挂载)"
  echo "---------------------------------------------"
  local certInput
  read -rp "请输入选项 [1-3] (直接回车默认独立模式申请): " certInput
  certInput=${certInput:-1}

  cert_path="/etc/singbox-vless-ws/fullchain.pem"
  key_path="/etc/singbox-vless-ws/privkey.pem"
  local acme_cmd="/root/.acme.sh/acme.sh"

  # 只要选了 1 或 3，都先确保安装好 acme.sh 基础组件
  if [[ $certInput == 1 || $certInput == 2 ]]; then
    info "正在检查并安装 Acme.sh 依赖..."
    if [[ ! -f "$acme_cmd" ]]; then
      curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
    fi
    "$acme_cmd" --set-default-ca --server letsencrypt
  fi

  if [[ $certInput == 1 ]]; then
    if ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "80"; then
      warn "检测到 80 端口已被占用，Acme 独立模式可能会失败。请确保已暂时关闭 Web 服务。"
    fi

    local vps_ip=$(get_public_ip)
    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
    
    info "正在向 Let's Encrypt 申请证书..."
    if [[ "$vps_ip" =~ ":" ]]; then
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    else
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi
    
    if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc --reloadcmd "systemctl restart singbox-vless-ws 2>/dev/null || pkill -f 'sing-box run' || true"; then
      echo "$domain" > /etc/singbox-vless-ws/ca.log
      sb_domain=$domain
      info "Acme 独立模式证书申请并成功分发！"
    else
      error "Acme 证书申请失败，自动切换回自定义证书路径。"
      certInput=2
    fi
    
  elif [[ $certInput == 3 ]]; then
    while true; do
      local user_cert user_key
      read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
      read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
      read -rp "请输入证书对应的域名: " sb_domain
      
      if [[ -f "$user_cert" && -f "$user_key" ]]; then
        rm -f "$cert_path" "$key_path"

        if [[ "$user_cert" == /root/* ]] || [[ "$user_key" == /root/* ]]; then
          warn "检测到您的外部证书源路径在 /root 目录下，正在修复目录穿透检索权限..."
          chmod +x "$(dirname "$user_cert")" 2>/dev/null || true
        fi
        
        chmod 644 "$user_cert" 2>/dev/null || true
        chmod 644 "$user_key" 2>/dev/null || true

        ln -sf "$user_cert" "$cert_path"
        ln -sf "$user_key" "$key_path"
        info "自定义证书已通过软链接无缝接入内部安全区。"
        break
      else
        error "找不到输入的证书文件，请重新输入或按 Ctrl+C 退出。"
        echo "---------------------------------------------"
      fi
    done

  elif [[ $certInput == 2 ]]; then
    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1

    echo "---------------------------------------------"
    echo "请选择 DNS 提供商："
    echo "1) cloudflare"
    echo "2) aliyun"
    echo "3) dnspod"
    echo "---------------------------------------------"
    local dns_provider
    read -rp "请输入选项 [1-3]: " dns_provider

    local dns_flag=""
    case "$dns_provider" in
      1)
        dns_flag="dns_cf"
        local cf_token cf_account
        read -rp "请输入 Cloudflare API Token (推荐) 或 Global API Key: " cf_token
        if [[ ${#cf_token} -eq 37 ]]; then
          export CF_Token="$cf_token"
        else
          export CF_Key="$cf_token"
          read -rp "请输入 Cloudflare 注册邮箱: " cf_account
          export CF_Email="$cf_account"
        fi
        ;;
      2)
        dns_flag="dns_ali"
        local ali_key ali_secret
        read -rp "请输入 阿里云 Ali_Key: " ali_key
        read -rp "请输入 阿里云 Ali_Secret: " ali_secret
        export Ali_Key="$ali_key"
        export Ali_Secret="$ali_secret"
        ;;
      3)
        dns_flag="dns_dp"
        local dp_id dp_key
        read -rp "请输入 DNSPod Token ID: " dp_id
        read -rp "请输入 DNSPod Token Key: " dp_key
        export DP_Id="$dp_id"
        export DP_Key="$dp_key"
        ;;
      *)
        error "无效输入，停止 API 申请。"
        return 1
        ;;
    esac

    info "正在通过 DNS API 向 Let's Encrypt 申请证书 (可能需要 1-2 分钟验证，请耐心等待)..."
    if "$acme_cmd" --issue --dns "$dns_flag" -d "$domain" -k ec-256 --insecure; then
      if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc --reloadcmd "systemctl restart singbox-vless-ws 2>/dev/null || pkill -f 'sing-box run' || true"; then
        echo "$domain" > /etc/singbox-vless-ws/ca.log
        sb_domain=$domain
        info "Acme DNS 模式证书申请成功且已配置自动续签指令！"
      else
        error "证书分发失败。"
        return 1
      fi
    else
      error "DNS API 证书申请失败，请确认 API 凭证与域名解析归属正确。"
      return 1
    fi
  fi

  # 规范化证书安全区的属性
  if [[ ! -L "$cert_path" ]]; then chmod 644 "$cert_path" 2>/dev/null || true; fi
  if [[ ! -L "$key_path" ]]; then chmod 600 "$key_path" 2>/dev/null || true; fi
  
  if is_user_exists "sing-box"; then
    chown -h sing-box:sing-box "$cert_path" "$key_path" 2>/dev/null || true
    chown sing-box:sing-box /etc/singbox-vless-ws 2>/dev/null || true
  fi
}

inst_port() {
  local default_port=""
  [[ -f "$SB_CONFIG" ]] && default_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "")

  local prompt_msg="设置 sing-box 主端口 [1-65535] (回车随机分配): "
  [[ -n "$default_port" ]] && prompt_msg="设置 sing-box 主端口 [当前: ${default_port}, 回车不修改]: "

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

configure_custom_socks5_outbound() {
    if [[ ! -f "$SB_CONFIG" ]]; then 
        error "错误: 未安装，无法配置出口模式。"
        return
    fi

    local mode current_type tmp_file
    current_type=$(jq -r '.outbounds[0].type // "direct"' "$SB_CONFIG" 2>/dev/null || echo "direct")

    echo "---------------------------------------------"
    echo "请选择出口模式："
    if [[ "$current_type" == "socks" ]]; then
        echo -e "当前模式: ${YELLOW}Socks5 代理出口${RESET}"
    else
        echo -e "当前模式: ${GREEN}本地直连出口${RESET}"
    fi
    echo "1) 直连出口"
    echo "2) Socks5出口"
    echo "0) 取消"
    echo "---------------------------------------------"

    read -rp "请输入选项 [0-2]: " mode || true
    case "$mode" in
        1)
            tmp_file=$(mktemp)
            jq '.outbounds = [{"type": "direct", "tag": "direct"}]' "$SB_CONFIG" > "$tmp_file"
            if ! jq empty "$tmp_file" >/dev/null 2>&1; then
                rm -f "$tmp_file"
                error "生成的直连配置无效。"
                return 1
            fi
            cp "$SB_CONFIG" "${SB_CONFIG}.bak.$(date +%s)"
            mv "$tmp_file" "$SB_CONFIG"
            chmod 644 "$SB_CONFIG" 2>/dev/null || true
            if is_user_exists "sing-box"; then chown sing-box:sing-box "$SB_CONFIG"; fi

            if ! restart_singbox_service; then
                error "切换到直连失败。"
                return 1
            fi
            info "已成功切换为直连出口！"
            return
            ;;
        2)
            ;;
        0|"")
            info "已取消配置。"
            return
            ;;
        *)
            error "无效选项，请输入 0-2 之间的数字。"
            return 1
            ;;
    esac

    info "配置自定义 Socks5 出口代理..."

    local socks_host socks_port socks_user socks_pass

    read -rp "请输入 Socks5 服务器地址/IP: " socks_host || true
    [[ -z "$socks_host" ]] && info "已取消配置。" && return

    while true; do
        read -rp "请输入 Socks5 端口 (默认: 1080): " socks_port || true
        [[ -z "$socks_port" ]] && socks_port=1080
        if is_valid_port "$socks_port"; then
            break
        else
            error "端口无效，请输入一个1-65535之间的数字。"
        fi
    done

    read -rp "请输入 Socks5 用户名 (若无密码认证请直接留空回车): " socks_user || true
    if [[ -n "$socks_user" ]]; then
        read -rs -p "请输入 Socks5 密码: " socks_pass || true
        echo
    else
        socks_pass=""
    fi

    tmp_file=$(mktemp)

    if [[ -n "$socks_user" ]]; then
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            --arg user "$socks_user" \
            --arg pass "$socks_pass" \
            '
            .outbounds = [
              {
                "type": "socks",
                "tag": "custom-socks5-out",
                "server": $host,
                "server_port": $port,
                "username": $user,
                "password": $pass
              }
            ]
            ' "$SB_CONFIG" > "$tmp_file"
    else
        jq \
            --arg host "$socks_host" \
            --argjson port "$socks_port" \
            '
            .outbounds = [
              {
                "type": "socks",
                "tag": "custom-socks5-out",
                "server": $host,
                "server_port": $port
              }
            ]
            ' "$SB_CONFIG" > "$tmp_file"
    fi

    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        error "生成的 Socks5 配置无效，请检查输入后重试。"
        return 1
    fi

    cp "$SB_CONFIG" "${SB_CONFIG}.bak.$(date +%s)"
    mv "$tmp_file" "$SB_CONFIG"
    chmod 644 "$SB_CONFIG" 2>/dev/null || true
    if is_user_exists "sing-box"; then chown sing-box:sing-box "$SB_CONFIG"; fi

    if ! restart_singbox_service; then
        error "重启服务失败，当前配置可能与系统环境不兼容。"
        return 1
    fi
    info "已成功切换为 Socks5 出口！"
}

write_and_show_config() {
  local hostname=$(hostname -s | sed 's/ /_/g')
  local ip=$(get_public_ip)
  local url_ip="$ip"
  if [[ "$ip" =~ ":" ]]; then 
    url_ip="[$ip]"
  fi

  cat << EOF > /etc/singbox-vless-ws/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$auth_pwd",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sb_domain",
        "key_path": "$key_path",
        "certificate_path": "$cert_path"
      },
      "transport": {
        "type": "ws",
        "path": "$ws_path"
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

  mkdir -p "$SB_DIR"

  cat << EOF > "$SB_DIR/url.txt"
====== VLESS + WS + TLS 节点信息 ======
IP    : ${ip}
端口  : $port
UUID  : $auth_pwd
SNI   : $sb_domain
HOST  : $sb_domain
路径  : $ws_path
---------------------------
📄 V6VPS 请自行替换 IP 地址为 V6 ★
[信息] V2rayN  链接：
vless://$auth_pwd@$url_ip:$port?sni=$sb_domain&host=$sb_domain&security=tls&type=ws&path=$(echo "$ws_path" | sed 's/\//%2F/g')#$hostname-Vlesswstls
---------------------------------
EOF

  if is_user_exists "sing-box"; then
    chown -R sing-box:sing-box /etc/singbox-vless-ws 2>/dev/null || true
  fi

  if restart_singbox_service; then
    info "sing-box (VLESS+WS+TLS) 服务配置并启动成功！"
  else
    error "sing-box 服务启动失败，请运行监控菜单查看日志。"
  fi
  
  showconf
}

# =========================================================
# 5. 主流程功能控制模块
# =========================================================
instsingbox() {
  check_environment
  
  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  if [[ -z "$latest_version" ]]; then
    error "无法获取最新版本号，请检查网络设置。"
    return 1
  fi
  
  local _tmparchive=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在解压并安装二进制可执行文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xzf "$_tmparchive" -C "$_tmpdir"
  
  if install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "安装失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  SINGBOX_USER="sing-box"
  SINGBOX_HOME_DIR="/var/lib/sing-box"
  if ! is_user_exists "$SINGBOX_USER"; then
    echo -ne "正在创建系统独立沙箱运行用户 $SINGBOX_USER ... "
    useradd -r -d "$SINGBOX_HOME_DIR" -m "$SINGBOX_USER" >/dev/null 2>&1 || true
    echo "成功"
  fi

  if has_command systemctl; then
    install_content -Dm644 "$(tpl_singbox_server_service_base 'config')" "$SYSTEMD_SERVICES_DIR/singbox-vless-ws.service" "1"
    install_content -Dm644 "$(tpl_singbox_server_service_base '%i')" "$SYSTEMD_SERVICES_DIR/singbox-vless-ws@.service" "1"
  fi

  inst_cert || return 1
  inst_port
  
  read -rp "设置 VLESS UUID (直接回车将自动分配强随机 UUID): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_uuid)}

  read -rp "设置 WebSocket 路径 (直接回车默认 /ws): " ws_path
  ws_path=${ws_path:-/ws}
  [[ ! "$ws_path" =~ ^/ ]] && ws_path="/$ws_path"

  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$SB_BINARY" ]]; then
    error "当前系统未安装 sing-box，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local latest_version=$(get_latest_version)

  if [[ -z "$latest_version" ]]; then
    error "无法连接 to GitHub API 获取最新版本，请稍后再试。"
    return 1
  fi

  info "当前安装版本: ${YELLOW}${current_version}${RESET}"
  info "官方最新版本: ${GREEN}${latest_version}${RESET}"

  if [[ "$current_version" == "$latest_version" ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "检测到新版本，即将开始平滑更新 (你的配置与运行数据不会改变)..."
  
  local _tmparchive=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xzf "$_tmparchive" -C "$_tmpdir"
  if install -Dm755 "$_tmpdir"/sing-box-*/sing-box "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  info "正在重启 sing-box 服务以应用更新..."
  if restart_singbox_service; then
    info "sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
  else
    error "核心更新成功，但服务重启失败。"
  fi
}

unstsingbox() {
  warn "即将从当前系统中彻底卸载 sing-box"

  if has_command systemctl; then
    systemctl stop singbox-vless-ws >/dev/null 2>&1 || true
    systemctl disable singbox-vless-ws >/dev/null 2>&1 || true
    remove_file "$SYSTEMD_SERVICES_DIR/singbox-vless-ws.service"
    remove_file "$SYSTEMD_SERVICES_DIR/singbox-vless-ws@.service"
    systemctl daemon-reload
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -rf /etc/singbox-vless-ws "$SB_DIR"

  info "sing-box 已彻底从您的系统中移除！"
}

changeconf() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "配置文件不存在，请先安装 sing-box"
    return 1
  fi

  local old_pwd=$(jq -r '.inbounds[0].users[0].uuid' "$SB_CONFIG" 2>/dev/null || true)
  local old_path=$(jq -r '.inbounds[0].transport.path' "$SB_CONFIG" 2>/dev/null || echo "/ws")
  local old_cert=$(jq -r '.inbounds[0].tls.certificate_path' "$SB_CONFIG" 2>/dev/null || true)
  local old_key=$(jq -r '.inbounds[0].tls.key_path' "$SB_CONFIG" 2>/dev/null || true)
  local old_sni=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG" 2>/dev/null || "www.bing.com")

  clear
  echo -e "${GREEN}====== 修改 sing-box (VLESS+WS+TLS) 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  inst_port 

  local auth_pwd
  read -rp "设置 VLESS 新 UUID [当前: ${old_pwd}, 回车不修改]: " auth_pwd
  auth_pwd=${auth_pwd:-$old_pwd}

  local ws_path
  read -rp "设置 新 WebSocket 路径 [当前: ${old_path}, 回车不修改]: " ws_path
  ws_path=${ws_path:-$old_path}
  [[ ! "$ws_path" =~ ^/ ]] && ws_path="/$ws_path"

  local cert_path key_path sb_domain
  echo "---------------------------------------------"
  read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
  if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
    inst_cert || return 1
  else
    cert_path="$old_cert"
    key_path="$old_key"
    sb_domain="$old_sni"
  fi

  write_and_show_config
  info "配置修改并应用成功！"
}

showconf() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "未找到 VLESS 配置文件，请确保已成功部署节点。"
    return
  fi

  local hostname=$(hostname -s | sed 's/ /_/g')
  local main_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG" 2>/dev/null || echo "18055")
  local auth_pwd=$(jq -r '.inbounds[0].users[0].uuid' "$SB_CONFIG" 2>/dev/null || echo "UUID")
  local sb_domain=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG" 2>/dev/null || echo "www.bing.com")
  local ws_path=$(jq -r '.inbounds[0].transport.path' "$SB_CONFIG" 2>/dev/null || echo "/ws")
  
  local is_insecure="0"
  if [[ "$sb_domain" == "www.bing.com" ]]; then
    is_insecure="1"
  fi

  local ip=$(get_public_ip)
  local url_ip="$ip"
  if [[ "$ip" =~ ":" ]]; then 
    url_ip="[$ip]"
  fi

  echo -e "${GREEN}====== VLESS + WS + TLS 节点信息 ======${RESET}"
  echo -e "${YELLOW}IP      : ${ip}${RESET}"
  echo -e "${YELLOW}端口    : ${main_port}${RESET}"
  echo -e "${YELLOW}UUID    : ${auth_pwd}${RESET}"
  echo -e "${YELLOW}SNI     : ${sb_domain}${RESET}"
  echo -e "${YELLOW}host     : ${sb_domain}${RESET}"
  echo -e "${YELLOW}WS 路径 : ${ws_path}${RESET}"
  echo -e "${GREEN}---------------------------${RESET}"
  echo -e "${YELLOW}📄 V6VPS 请自行替换 IP 地址为 V6 ★${RESET}"
  echo -e "${GREEN}[信息] V2rayN 链接：${RESET}"
  echo -e "${YELLOW}vless://${auth_pwd}@${url_ip}:${main_port}?sub=1&sni=${sb_domain}&host=${sb_domain}&security=tls&allowInsecure=${is_insecure}&type=ws&path=$(echo "$ws_path" | sed 's/\//%2F/g')#${hostname}-Vlesswstls${RESET}"
  echo -e "${YELLOW}---------------------------------${RESET}"
}

# =========================================================
# 6. 面板主菜单循环
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
    echo -e "${GREEN}    Sing-box VLESS-WS-TLS 面板  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1.安装 Sing-box VLESS-WS-TLS${RESET}"
    echo -e "${GREEN} 2.更新 Sing-box ${RESET}"
    echo -e "${GREEN} 3.卸载 Sing-box ${RESET}"
    echo -e "${GREEN} 4.修改配置${RESET}"
    echo -e "${GREEN} 5.启动 Sing-box ${RESET}"
    echo -e "${GREEN} 6.停止 Sing-box ${RESET}"
    echo -e "${GREEN} 7.重启 Sing-box ${RESET}"
    echo -e "${GREEN} 8.查看日志${RESET}"
    echo -e "${GREEN} 9.查看节点配置${RESET}"
    echo -e "${GREEN}10.配置Socks5出口${RESET}"
    echo -e "${GREEN} 0.退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) instsingbox; pause ;;
      2) update_singbox; pause ;;
      3) unstsingbox; pause ;;
      4) changeconf; pause ;;
      5) 
        if has_command systemctl; then
          systemctl start singbox-vless-ws && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop singbox-vless-ws && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart singbox-vless-ws && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --config "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u singbox-vless-ws.service -n 50 --no-pager
        else
          warn "当前环境不支持 systemd 集中日志管理。"
        fi
        pause ;;
      9) showconf; pause ;;
      10) configure_custom_socks5_outbound; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
