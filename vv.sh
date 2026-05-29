#!/usr/bin/env bash
#
# Alpine sing-box TUIC v5 管理面板
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly BINARY_PATH="/usr/local/bin/sing-box"
readonly TUIC_CONFIG="/etc/sing-box/config.json"
readonly TUIC_DIR="/root/tuicV5"
CONFIG_DIR="/etc/sing-box"
OPENRC_SERVICE_PATH="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"
RUN_USER="singbox"

TMP_DIR=$(mktemp -d -t singbox.XXXXXX)

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
  apk add --no-cache bash curl wget tar openssl openrc iproute2 jq grep sed coreutils bind-tools iptables
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
    # 提取纯粹的版本数字，不带多余的 sing-box version 字符串
    "$BINARY_PATH" version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知版本"
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local latest_v=""
  
  # 方法 1：尝试通过 API 获取
  latest_v=$(curl -sSL --max-time 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || true)
  
  # 方法 2：如果 API 失败或被限流，通过直连 headers 重定向获取真实版本号
  if [[ -z "$latest_v" || "$latest_v" == "null" ]]; then
    latest_v=$(curl -sIL -o /dev/null -w "%{url_effective}" --max-time 3 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | awk -F'/' '{print $NF}' || true)
  fi

  # 过滤掉版本号前面的 "v" 字符
  latest_v=${latest_v#v}
  # 清理可能存在的换行或空格
  latest_v=$(echo "$latest_v" | tr -d '[:space:]')

  # 保底机制：如果上面都失败了，强制指定一个 2026 年已知非常稳定的正式版本号（例如 1.13.12）
  if [[ -z "$latest_v" || "$latest_v" == "null" || ! "$latest_v" =~ ^[0-9]+\.[0-9]+ ]]; then
    warn "未能通过网络获取到最新版本号，启用保底版本: 1.13.12"
    echo "1.13.12"
  else
    echo "$latest_v"
  fi
}

clear_old_iptables() {
  if [[ -f "${CONFIG_DIR}/hopping.txt" && -f "${CONFIG_DIR}/main_port.txt" ]]; then
    local old_hop=$(cat "${CONFIG_DIR}/hopping.txt")
    local old_port=$(cat "${CONFIG_DIR}/main_port.txt")
    local old_start=${old_hop%-*}
    local old_end=${old_hop#*-}

    if [[ -n "$old_start" && -n "$old_end" && -n "$old_port" ]]; then
      iptables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
      ip6tables -t nat -D PREROUTING -p udp --dport "$old_start:$old_end" -j REDIRECT --to-ports "$old_port" 2>/dev/null || true
    fi
  fi
}

apply_new_iptables() {
  clear_old_iptables
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local hop_val=$(cat "${CONFIG_DIR}/hopping.txt")
    local start_p=${hop_val%-*}
    local end_p=${hop_val#*-}
    
    info "正在应用 iptables 转发规则: UDP $start_p-$end_p => 主端口 $port"
    iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port"
    ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    
    echo "$port" > "${CONFIG_DIR}/main_port.txt"
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

get_tuic_status() {
  if rc-service sing-box status 2>/dev/null | grep -q "started"; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

get_current_port_display() {
  if [[ -f "$TUIC_CONFIG" ]]; then
    local main_port jump_range="无"
    main_port=$(jq -r '.inbounds[0].listen_port // empty' "$TUIC_CONFIG" 2>/dev/null)
    [[ -f "${CONFIG_DIR}/hopping.txt" ]] && jump_range=$(cat "${CONFIG_DIR}/hopping.txt")
    
    if [[ "$jump_range" != "无" ]]; then
      echo "${main_port} [${jump_range}]"
    else
      echo "${main_port:- -}"
    fi
  else echo "-"; fi
}



# =========================================================
# 5. 面板节点配置生成核心逻辑
# =========================================================
inst_cert() {
  mkdir -p "$CONFIG_DIR/certs"

  echo "---------------------------------------------"
  echo -e "Tuic 协议证书申请方式如下："
  echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
  echo -e " 2) Acme 脚本自动申请 (需放放行 80 端口)"
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

  echo "---------------------------------------------"
  echo -e "Tuic 端口群使用模式 ："
  echo -e " 1) 单端口模式"
  echo -e " 2) 端口跳跃模式 ${YELLOW}（默认)${RESET}"
  echo "---------------------------------------------"
  local jumpInput
  read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
  jumpInput=${jumpInput:-2}

  clear_old_iptables

  if [[ $jumpInput == 2 ]]; then
    while true; do
      read -rp "设置外部跳跃起始端口 (建议10000-65535): " firstport
      read -rp "设置外部跳跃末尾端口 (必须大于起始端口): " endport
      if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then break
      else error "输入无效，起始端口必须小于末尾端口，请重新输入。"; fi
    done
    echo "$firstport-$endport" > "${CONFIG_DIR}/hopping.txt"
  else
    rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt"
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
      "listen_port": $port,
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

  apply_new_iptables
  mkdir -p "$TUIC_DIR"
  
  local hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  cat << EOF > "$TUIC_DIR/url.txt"
V6VPS 请自行替换 IP 地址为 V6
V2rayN 链接:
tuic://$auth_uuid:$auth_pwd@$last_ip:$port?alpn=h3&congestion_control=bbr&sni=$tuic_domain&allow_insecure=${is_insecure}${hopping_param}#$HOSTNAME-tuicv5

Surge 配置:
$HOSTNAME-tuicv5 = tuic-v5, $last_ip, $port, password=$auth_pwd, uuid=$auth_uuid, ecn=true, skip-cert-verify=${skip_cert}, sni=$tuic_domain
EOF

  rc-service sing-box restart
  if rc-service sing-box status | grep -q "started"; then
    info "sing-box TUIC 服务配置并启动成功！"
  else
    error "sing-box 启动失败，可在菜单中按 8 查看详细的闪退日志。"
  fi
  showconf
}

# =========================================================
# 6. 安装、更新与卸载核心流控
# =========================================================
write_openrc_script() {
  cat << 'EOF' > "$OPENRC_SERVICE_PATH"
#!/sbin/openrc-run

name="sing-box"
description="sing-box TUIC OpenRC Service"
cfgfile="/etc/sing-box/config.json"
logfile="/var/log/sing-box.log"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f "$cfgfile" ]; then
        eerror "Configuration file $cfgfile missing!"
        return 1
    fi
    
    # 强行打通并创建底层物理日志节点
    touch "$logfile"
    chown singbox:singbox "$logfile"
    chmod 644 "$logfile"
    
    command_background="yes"
    pidfile="/run/${RC_SVCNAME}.pid"
    
    # 将标准错误与标准输出双向绑定回物理日志，抓取一切闪退现场
    output_log="$logfile"
    error_log="$logfile"
    
    local port
    port=$(jq -r '.inbounds[0].listen_port // 0' "$cfgfile" 2>/dev/null)
    if [ "$port" -lt 1024 ] && [ "$port" -ne 0 ]; then
        command_user="root:root"
    else
        command_user="singbox:singbox"
    fi
}
EOF
  chmod +x "$OPENRC_SERVICE_PATH"
  rc-update add sing-box default >/dev/null 2>&1 || true
}

download_core() {
  local arch url current_version
  arch=$(detect_arch)
  
  # 动态获取最新版本号
  current_version=$(get_latest_version)
  
  if [[ -z "$current_version" ]]; then
    error "无法确定需要下载的 sing-box 版本号"
    return 1
  fi
  
  # 拼接官方 GitHub Release 规范的下载直链
  url=$(printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' "$current_version" "$current_version" "$arch")
  
  info "正在下载官方核心 sing-box v$current_version ..."
  cd "$TMP_DIR"
  
  # 优先使用 wget，失败则降级使用 curl
  if ! wget -O sing-box.tar.gz -q "$url"; then
    if ! curl -fsSL -o sing-box.tar.gz "$url"; then
      error "下载核心文件失败！请检查网络是否能正常访问 GitHub。"
      error "尝试请求的下载链接为: $url"
      return 1
    fi
  fi
  
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  # 安全停止并替换原生二进制
  rc-service sing-box stop >/dev/null 2>&1 || true
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box v$current_version 核心释放完毕。"
  return 0
}

install_tuic() {
  echo -e "${GREEN}[信息] 开始在 Alpine 下部署 sing-box TUIC V5 ...${RESET}"
  check_environment
  mkdir -p "$CONFIG_DIR" "$TUIC_DIR"

  local arch url
  arch=$(detect_arch)
  url=$(printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' "$SINGBOX_VERSION" "$SINGBOX_VERSION" "$arch")
  
  info "正在下载官方核心 sing-box v$SINGBOX_VERSION..."
  cd "$TMP_DIR"
  if ! wget -O sing-box.tar.gz -q "$url"; then
    curl -fsSL -o sing-box.tar.gz "$url" || { error "下载核心文件失败"; return 1; }
  fi
  
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标核心错误"; return 1; }
  
  install -m 755 "$extracted" "$BINARY_PATH"
  info "sing-box 核心下载并释放完毕。"

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
    error "当前系统未检测到核心，无法执行覆盖升级。"
    return 1
  fi
  info "检测到已有环境，正在执行纯净原地覆盖核心升级（不破坏任何节点配置）..."
  if download_core; then
    rc-service sing-box start
    info "sing-box 核心纯净升级覆盖成功，服务已安全启动！"
  else
    error "核心升级遭遇未预期中断。"
  fi
}

unsttuic() {
  warn "即将卸载..."
  clear_old_iptables

  rc-service sing-box stop || true
  rc-update del sing-box default >/dev/null 2>&1 || true
  
  rm -f "$BINARY_PATH" "$OPENRC_SERVICE_PATH" "$LOG_FILE"
  rm -rf "$CONFIG_DIR" "$TUIC_DIR"
  
  info "彻底卸载清理完毕！"
}

changeconf() {
  if [[ ! -f "$TUIC_CONFIG" ]]; then
    error "配置文件不存在，请先选择选项 1 安装"
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
  info "配置与转发链条刷新修改成功！"
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



# =========================================================
# 7. 面板交互菜单 
# =========================================================
menu() {
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
    echo -e "${GREEN}    Sing-box(Tuicv5) 管理面板   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status}"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}2. 更新 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}3. 卸载 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box Tuicv5${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) install_tuic; pause ;;
      2) update_tuic; pause ;;
      3) rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt" 2>/dev/null; unsttuic; pause ;;
      4) changeconf; pause ;;
      5) rc-service sing-box start && info "服务已成功启动！"; pause ;;
      6) rc-service sing-box stop && info "服务已成功停止！"; pause ;;
      7) rc-service sing-box restart && info "服务已成功重启！"; pause ;;
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
