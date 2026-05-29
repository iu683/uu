#!/usr/bin/env bash
#
# Alpine sing-box TUIC v5 极客管理面板
# SPDX-License-Identifier: MIT
#
set -Eop pipefail
export LANG=en_US.UTF-8

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
readonly SINGBOX_VERSION="1.12.0"
readonly BINARY_PATH="/usr/local/bin/sing-box"
readonly TUIC_CONFIG="/etc/sing-box/config.json"
readonly TUIC_DIR="/root/tuicV5"
CONFIG_DIR="/etc/sing-box"
OPENRC_SERVICE_PATH="/etc/init.d/sing-box"
SYSCTL_FILE="/etc/sysctl.d/99-singbox-tuic.conf"
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

manage_udp_jump() {
  local action="$1"
  local start_p="${2:-}"
  local end_p="${3:-}"
  local main_p="${4:-}"

  # 无论何种操作，先清洗掉文件中记录的旧规则链条条目
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

  if [[ "$action" == "add" && -n "$start_p" && -n "$end_p" && -n "$main_p" ]]; then
    info "正在建立 iptables 端口群转发: UDP $start_p-$end_p => 主端口 $main_p"
    iptables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$main_p"
    ip6tables -t nat -A PREROUTING -p udp --dport "$start_p:$end_p" -j REDIRECT --to-ports "$main_p" 2>/dev/null || true
    
    echo "$start_p-$end_p" > "${CONFIG_DIR}/hopping.txt"
    echo "$main_p" > "${CONFIG_DIR}/main_port.txt"
  elif [[ "$action" == "remove" ]]; then
    rm -f "${CONFIG_DIR}/hopping.txt" "${CONFIG_DIR}/main_port.txt"
    info "已成功下线并清洗所有 UDP 端口跳跃转发规则。"
  fi
}

enable_bbr() {
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
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
# 5. 面板节点配置生成与更新
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
    read -rp "请输入需要申请证书的域名: " domain
    [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
    local acme_cmd="/root/.acme.sh/acme.sh"
    if [[ ! -f "$acme_cmd" ]]; then
      curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
    fi
    "$acme_cmd" --set-default-ca --server letsencrypt
    if [[ "$(get_public_ip)" =~ ":" ]]; then
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    else
      "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi
    if "$acme_cmd" --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc; then
      echo "$domain" > "$CONFIG_DIR/certs/ca.log"
      tuic_domain=$domain
    else
      certInput=1
    fi
  elif [[ $certInput == 3 ]]; then
    local user_cert user_key
    read -rp "请输入公钥文件 (fullchain.pem/crt) 的路径: " user_cert
    read -rp "请输入密钥文件 (privkey.pem/key) 的路径: " user_key
    read -rp "请输入证书对应的域名: " tuic_domain
    if [[ -f "$user_cert" && -f "$user_key" ]]; then
      cp -f "$user_cert" "$cert_path"
      cp -f "$user_key" "$key_path"
    else
      certInput=1
    fi
  fi

  if [[ $certInput == 1 ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
    tuic_domain="www.bing.com"
  fi

  chmod 644 "$cert_path"
  chmod 600 "$key_path"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR/certs"
}

refresh_share_url() {
  [[ -f "$TUIC_CONFIG" ]] || return 0
  local current_port=$(jq -r '.inbounds[0].listen_port' "$TUIC_CONFIG")
  local current_uuid=$(jq -r '.inbounds[0].users[0].uuid' "$TUIC_CONFIG")
  local current_pwd=$(jq -r '.inbounds[0].users[0].password' "$TUIC_CONFIG")
  local current_sni=$(jq -r '.inbounds[0].tls.server_name' "$TUIC_CONFIG")
  
  local HOSTNAME=$(hostname -s | sed 's/ /_/g')
  local vps_ip=$(get_public_ip)
  local last_ip="$vps_ip"
  [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

  local is_insecure="0"
  local skip_cert="false"
  if [[ "$current_sni" == "www.bing.com" ]]; then
    is_insecure="1"
    skip_cert="true"
  fi

  local hopping_param=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    hopping_param="&mport=$(cat "${CONFIG_DIR}/hopping.txt")"
  fi

  mkdir -p "$TUIC_DIR"
  cat << EOF > "$TUIC_DIR/url.txt"
V6VPS 请自行替换 IP 地址为 V6
V2rayN 链接:
tuic://$current_uuid:$current_pwd@$last_ip:$current_port?alpn=h3&congestion_control=bbr&sni=$current_sni&allow_insecure=${is_insecure}${hopping_param}#$HOSTNAME-singbox-tuic

Surge 配置:
$HOSTNAME-tuic = tuic-v5, $last_ip, $current_port, password=$current_pwd, uuid=$current_uuid, ecn=true, skip-cert-verify=${skip_cert}, sni=$current_sni

Clash Meta / Mihomo 格式备忘:
- name: $HOSTNAME-tuic
  type: tuic
  server: $vps_ip
  port: $current_port
  uuid: $current_uuid
  password: $current_pwd
  alpn: [h3]
  sni: $current_sni
  skip-cert-verify: ${skip_cert}
EOF
}

# =========================================================
# 6. 核心流程控制
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
    touch "$logfile"
    chown singbox:singbox "$logfile"
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
        command_user="singbox:singbox"
    fi
}
EOF
  chmod +x "$OPENRC_SERVICE_PATH"
  rc-update add sing-box default >/dev/null 2>&1 || true
}

download_core() {
  local arch url
  arch=$(detect_arch)
  url=$(printf 'https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-linux-%s.tar.gz' "$SINGBOX_VERSION" "$SINGBOX_VERSION" "$arch")
  
  info "正在获取官方官方核心二进制包..."
  cd "$TMP_DIR"
  if ! wget -O sing-box.tar.gz -q "$url"; then
    curl -fsSL -o sing-box.tar.gz "$url" || { error "核心下载异常阻断"; return 1; }
  fi
  tar -xzf sing-box.tar.gz -C "$TMP_DIR"
  local extracted=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
  [[ -n "$extracted" ]] || { error "解压目标数据不全"; return 1; }
  
  rc-service sing-box stop || true
  install -m 755 "$extracted" "$BINARY_PATH"
  return 0
}

install_tuic() {
  echo -e "${GREEN}[信息] 开始在 Alpine 下部署 sing-box TUIC V5 ...${RESET}"
  check_environment
  mkdir -p "$CONFIG_DIR" "$TUIC_DIR"

  download_core || return 1
  write_openrc_script
  enable_bbr
  inst_cert || return 1

  while true; do
    read -rp "设置 Tuic 服务端监听主端口 [1-65535] (回车随机分配): " port
    port=${port:-$(get_random_port)}
    if is_valid_port "$port" && check_port "$port"; then break; else error "端口不可用，重新输入"; fi
  done
  
  read -rp "设置 Tuic 验证 UUID (回车自动分配随机 UUID): " auth_uuid
  auth_uuid=${auth_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "12345678-1234-1234-1234-123456781234")}
  read -rp "设置 Tuic 验证密码 (回车自动分配随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  cat << EOF > "$TUIC_CONFIG"
{
  "log": { "level": "info", "output": "$LOG_FILE", "timestamp": true },
  "inbounds": [{
      "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $port,
      "users": [{ "uuid": "$auth_uuid", "password": "$auth_pwd" }],
      "congestion_control": "bbr", "zero_rtt_handshake": false, "heartbeat": "10s",
      "tls": { "enabled": true, "server_name": "$tuic_domain", "alpn": ["h3"], "certificate_path": "$cert_path", "key_path": "$key_path" }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
EOF
  chmod 640 "$TUIC_CONFIG"
  chown -R ${RUN_USER}:${RUN_USER} "$CONFIG_DIR"
  
  refresh_share_url
  rc-service sing-box start
  showconf
}

update_tuic() {
  if [[ ! -f "$BINARY_PATH" ]]; then
    error "当前系统未检测到核心，无法执行覆盖升级。"
    return 1
  fi
  info "当前检测到已有配置，正在执行纯净原地更新核心流程..."
  if download_core; then
    rc-service sing-box start
    info "sing-box 核心升级覆盖完毕，服务已安全复位运行！"
  else
    error "核心升级遭遇阻断。"
  fi
}

change_jump_rules() {
  if [[ ! -f "$TUIC_CONFIG" ]]; then
    error "配置文件缺失，无法配置跳跃逻辑。"
    return 1
  fi
  
  local new_port=$(jq -r '.inbounds[0].listen_port' "$TUIC_CONFIG")
  local current_start="" current_end=""
  if [[ -f "${CONFIG_DIR}/hopping.txt" ]]; then
    local current_hop=$(cat "${CONFIG_DIR}/hopping.txt")
    current_start=${current_hop%-*}
    current_end=${current_hop#*-}
  fi

  clear
  echo -e "${GREEN}====== # 4. 修改跳跃规则 ======${RESET}"
  echo -e "${YELLOW}提示: 若需取消跳跃，请在起始端口输入 'off'${RESET}"
  read -rp "$(echo -e ${GREEN}"设置跳跃起始端口 (当前: ${current_start:-未设置}): "${RESET})" new_start
  new_start=${new_start:-$current_start}

  if [[ "$new_start" == "off" ]]; then
    manage_udp_jump "remove"
  elif [[ -n "$new_start" ]]; then
    read -rp "$(echo -e ${GREEN}"设置跳跃末尾端口 (当前: ${current_end:-未设置}): "${RESET})" new_end
    new_end=${new_end:-$current_end}
    
    if [[ -n "$new_end" && "$new_end" -gt "$new_start" ]]; then
      manage_udp_jump "add" "$new_start" "$new_end" "$new_port"
    else
      error "末尾端口必须大于起始端口，跳跃设置未变更。"
    fi
  fi
  refresh_share_url
}

unsttuic() {
  warn "正在从 Alpine 中完全清理并摘除服务组件..."
  manage_udp_jump "remove"
  rc-service sing-box stop || true
  rc-update del sing-box default >/dev/null 2>&1 || true
  rm -f "$BINARY_PATH" "$OPENRC_SERVICE_PATH" "$SYSCTL_FILE" "$LOG_FILE"
  rm -rf "$CONFIG_DIR" "$TUIC_DIR"
  info "彻底清洗完毕！"
}

showconf() {
  if [[ -f "$TUIC_DIR/url.txt" ]]; then
    echo -e "${GREEN}====== 节点分享与配置信息 ======${RESET}"
    cat "$TUIC_DIR/url.txt"
    echo
  else error "无分享数据"; fi
}

# =========================================================
# 7. 面板交互主菜单
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
    echo -e "${GREEN}       Tuic v5 管理面板         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status}"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Tuic${RESET}"
    echo -e "${GREEN}2. 更新 Tuic${RESET}"
    echo -e "${GREEN}3. 卸载 Tuic${RESET}"
    echo -e "${GREEN}4. 修改跳跃规则${RESET}"
    echo -e "${GREEN}5. 启动 Tuic${RESET}"
    echo -e "${GREEN}6. 停止 Tuic${RESET}"
    echo -e "${GREEN}7. 重启 Tuic${RESET}"
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
      3) unsttuic; pause ;;
      4) change_jump_rules; pause ;;
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
