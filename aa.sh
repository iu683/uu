#!/usr/bin/env bash
#
# Xray-Argo 一体化管理面板 
# SPDX-License-Identifier: MIT
#

# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# ==========================================
# 隔离定义：重定义所有名称与路径，防止与其他脚本冲突
# ==========================================
readonly SERVER_NAME="xray-mix"
readonly WORK_DIR="/etc/xray_argo_mix"
readonly CONFIG_DIR="${WORK_DIR}/config.json"
readonly CLIENT_DIR="${WORK_DIR}/url.txt"
readonly OUTBOUND_ENV_FILE="${WORK_DIR}/outbound.env"

# 服务命名隔离
readonly XRAY_SERVICE_NAME="xray-mix"
readonly ARGO_SERVICE_NAME="tunnel-mix"

# 动态环境变量初始化
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")}
export PORT=${PORT:-$(shuf -i 1000-60000 -n 1 2>/dev/null || echo "4433") }
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'ip.sb'} 
export CFPORT=${CFPORT:-'443'}
export OUTBOUND_MODE=${OUTBOUND_MODE:-'direct'}
export SOCKS5_HOST=${SOCKS5_HOST:-''}
export SOCKS5_PORT=${SOCKS5_PORT:-'1080'}
export SOCKS5_USER=${SOCKS5_USER:-''}
export SOCKS5_PASS=${SOCKS5_PASS:-''}

# 终端高亮颜色定义
RE="\033[0m"
RED="\033[1;91m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
PURPLE="\033[1;35m"
SKYBLUE="\033[1;36m"
CYAN="\033[1;36m"
RESET="\033[0m"

# 核心日志输出快捷工具
red() { echo -e "${RED}$*${RE}" >&2; }
green() { echo -e "${GREEN}$*${RE}" >&2; }
yellow() { echo -e "${YELLOW}$*${RE}" >&2; }
purple() { echo -e "${PURPLE}$*${RE}" >&2; }
skyblue() { echo -e "${SKYBLUE}$*${RE}" >&2; }
reading() { read -rp "$(echo -e "${GREEN}$1${RE}")" "$2"; }
pause() { read -n 1 -s -r -p "$(echo -e "${RED}按任意键继续...${RE}")" || true; echo; }

# 权限隔离自检
[[ $EUID -ne 0 ]] && { red "请在 root 用户下运行此脚本！"; exit 1; }

# =========================================================
# 2. 底层运行状态自检模块
# =========================================================
is_alpine() { [[ -f /etc/alpine-release ]]; }

check_xray() {
  if [[ -f "${WORK_DIR}/${SERVER_NAME}" ]]; then
    if is_alpine; then
      rc-service ${XRAY_SERVICE_NAME} status 2>/dev/null | grep -q "started" && return 0 || return 1
    else 
      [[ "$(systemctl is-active ${XRAY_SERVICE_NAME} 2>/dev/null)" = "active" ]] && return 0 || return 1
    fi
  else
    return 2
  fi
}

check_argo() {
  if [[ -f "${WORK_DIR}/argo" ]]; then
    if is_alpine; then
      rc-service ${ARGO_SERVICE_NAME} status 2>/dev/null | grep -q "started" && return 0 || return 1
    else 
      [[ "$(systemctl is-active ${ARGO_SERVICE_NAME} 2>/dev/null)" = "active" ]] && return 0 || return 1
    fi
  else
    return 2
  fi
}

get_xray_status_msg() {
  local status_code
  check_xray && status_code=$? || status_code=$?
  case "$status_code" in
    0) echo -e "${GREEN}● 运行中${RE}" ;;
    1) echo -e "${YELLOW}● 未运行${RE}" ;;
    *) echo -e "${RED}● 未安装${RE}" ;;
  esac
}

get_argo_status_msg() {
  local status_code
  check_argo && status_code=$? || status_code=$?
  case "$status_code" in
    0) echo -e "${GREEN}● 运行中${RE}" ;;
    1) echo -e "${YELLOW}● 未运行${RE}" ;;
    *) echo -e "${RED}● 未安装${RE}" ;;
  esac
}

# =========================================================
# 3. 系统适配与高级包管理器驱动
# =========================================================
manage_packages() {
  [[ $# -lt 2 ]] && { red "未指定包名或动作"; return 1; }
  local action="$1" && shift

  for package in "$@"; do
    if [[ "$action" == "install" ]]; then
      command -v "$package" &>/dev/null && { green "${package} 已存在，跳过安装"; continue; }
      yellow "正在安装依赖工具: ${package}..."
      if command -v apt &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt install -y "$package"
      elif command -v dnf &>/dev/null; then
        dnf install -y "$package"
      elif command -v yum &>/dev/null; then
        yum install -y "$package"
      elif command -v apk &>/dev/null; then
        apk update && apk add "$package"
      else
        red "未知的系统组件，请手动安装 ${package}" && return 1
      fi
    elif [[ "$action" == "uninstall" ]]; then
      ! command -v "$package" &>/dev/null && { yellow "${package} 未安装，无需处理"; continue; }
      yellow "正在卸载 ${package}..."
      if command -v apt &>/dev/null; then
        apt remove -y "$package" && apt autoremove -y
      elif command -v dnf &>/dev/null; then
        dnf remove -y "$package" && dnf autoremove -y
      elif command -v yum &>/dev/null; then
        yum remove -y "$package" && yum autoremove -y
      elif command -v apk &>/dev/null; then
        apk del "$package"
      fi
    fi
  done
}

get_realip() {
  local ip ipv6
  ip=$(curl -s --max-time 2 ipv4.ip.sb || echo "")
  if [[ -z "$ip" ]]; then
    ipv6=$(curl -s --max-time 2 ipv6.ip.sb || echo "")
    echo "[$ipv6]"
  else
    if curl -s http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
      ipv6=$(curl -s --max-time 2 ipv6.ip.sb || echo "")
      echo "[$ipv6]"
    else
      echo "$ip"
    fi
  fi
}

HOSTNAME=$(hostname -s | sed 's/ /_/g' || echo "Xray_Node")

# =========================================================
# 4. 出口核心环境控制与配置引擎
# =========================================================
load_outbound_env() {
  [[ -f "$OUTBOUND_ENV_FILE" ]] && source "$OUTBOUND_ENV_FILE"
}

save_outbound_env() {
  mkdir -p "$WORK_DIR"
  cat <<EOF > "$OUTBOUND_ENV_FILE"
OUTBOUND_MODE='$OUTBOUND_MODE'
SOCKS5_HOST='$SOCKS5_HOST'
SOCKS5_PORT='$SOCKS5_PORT'
SOCKS5_USER='$SOCKS5_USER'
SOCKS5_PASS='$SOCKS5_PASS'
EOF
}

load_outbound_env

build_outbounds_json() {
  if [[ "$OUTBOUND_MODE" = "socks5" ]]; then
    [[ -z "$SOCKS5_HOST" ]] && { red "OUTBOUND_MODE=socks5 时必须设置 SOCKS5_HOST"; exit 1; }
    if [[ -n "$SOCKS5_USER" ]] || [[ -n "$SOCKS5_PASS" ]]; then
      cat <<EOF
[
  {
    "protocol": "socks",
    "tag": "proxy",
    "settings": {
      "servers": [
        {
          "address": "$SOCKS5_HOST",
          "port": $SOCKS5_PORT,
          "users": [
            {
              "user": "$SOCKS5_USER",
              "pass": "$SOCKS5_PASS"
            }
          ]
        }
      ]
    }
  },
  {
    "protocol": "freedom",
    "tag": "direct"
  }
]
EOF
    else
      cat <<EOF
[
  {
    "protocol": "socks",
    "tag": "proxy",
    "settings": {
      "servers": [
        {
          "address": "$SOCKS5_HOST",
          "port": $SOCKS5_PORT
        }
      ]
    }
  },
  {
    "protocol": "freedom",
    "tag": "direct"
  }
]
EOF
    fi
  else
    cat <<EOF
[
  {
    "protocol": "freedom",
    "tag": "direct"
  }
]
EOF
  fi
}

build_routing_json() {
  if [[ "$OUTBOUND_MODE" = "socks5" ]]; then
    cat <<EOF
,
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
EOF
  fi
}

rebuild_xray_config() {
  [[ ! -d "$WORK_DIR" ]] && { red "Xray 尚未安装"; return 1; }
  local outbounds_json=$(build_outbounds_json)
  local routing_json=$(build_routing_json)

  # 内部回落端口也一并加上偏移（原3001-3003改为13001-13003），死死隔离
  cat <<EOF > "${CONFIG_DIR}"
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none",
        "fallbacks": [
          { "dest": 13001 }, 
          { "path": "/vless-argo", "dest": 13002 },
          { "path": "/vmess-argo", "dest": 13003 }
        ]
      },
      "streamSettings": { "network": "tcp" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "port": 13001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" }
    },
    {
      "port": 13002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-argo" } }
    },
    {
      "port": 13003, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } }
    }
  ],
  "outbounds": $outbounds_json$routing_json
}
EOF
}

configure_socks5_outbound() {
  [[ ! -f "$CONFIG_DIR" ]] && { yellow "请先安装 Xray"; return 1; }

  clear
  green "================================="
  green "         出口模式设置            "
  green "================================="
  green " 1. 直连出口"
  green " 2. 自定义SOCKS5"
  purple " 0. 返回主菜单"
  green "================================="
  local outbound_choice
  reading "请输入选择 [0-2]: " outbound_choice

  case "$outbound_choice" in
    1)
      OUTBOUND_MODE="direct"
      SOCKS5_HOST=""
      SOCKS5_PORT="1080"
      SOCKS5_USER=""
      SOCKS5_PASS=""
      save_outbound_env
      rebuild_xray_config || return 1
      restart_xray
      green "已成功切换为：直连本地出口机制"
      ;;
    2)
      reading "请输入 SOCKS5 远程地址: " custom_socks5_host
      [[ -z "$custom_socks5_host" ]] && { red "错误：SOCKS5 地址不能为空"; return 1; }

      reading "请输入 SOCKS5 端口(默认 1080): " custom_socks5_port
      custom_socks5_port=${custom_socks5_port:-1080}
      if ! [[ "$custom_socks5_port" =~ ^[0-9]+$ ]] || [ "$custom_socks5_port" -lt 1 ] || [ "$custom_socks5_port" -gt 65535 ]; then
        red "错误：非法的端口范围" && return 1
      fi

      reading "请输入 SOCKS5 用户名(留空跳过): " custom_socks5_user
      reading "请输入 SOCKS5 验证密码(留空跳过): " custom_socks5_pass

      OUTBOUND_MODE="socks5"
      SOCKS5_HOST="$custom_socks5_host"
      SOCKS5_PORT="$custom_socks5_port"
      SOCKS5_USER="$custom_socks5_user"
      SOCKS5_PASS="$custom_socks5_pass"

      save_outbound_env
      rebuild_xray_config || return 1
      restart_xray
      green "成功挂载 SOCKS5 出口隧道: ${SOCKS5_HOST}:${SOCKS5_PORT}"
      ;;
    0) return 0 ;;
    *) red "无效的选项！" ;;
  esac
}

# =========================================================
# 5. 组件安装与系统服务治理引擎
# =========================================================
install_xray() {
  clear
  purple "正在部署高端智能化隔离版 Xray-Argo 双栈系统，请稍候..."
  
  local ARCH_RAW=$(uname -m)
  local ARCH ARCH_ARG
  case "${ARCH_RAW}" in
    'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
    'x86' | 'i686' | 'i386') ARCH='386'; ARCH_ARG='32' ;;
    'aarch64' | 'arm64') ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
    'armv7l') ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
    's390x') ARCH='s390x' ;;
    *) red "本系统不支持当前服务器架构: ${ARCH_RAW}"; exit 1 ;;
  esac

  # GITHUB 代理数组
  local GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
  )

  mkdir -p "${WORK_DIR}" && chmod 755 "${WORK_DIR}"

  # 定义组件的下载相对路径
  local XRAY_URL_PATH="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip"
  local ARGO_URL_PATH="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"

  # 循环下载 Xray
  local success=false
  for proxy in "${GITHUB_PROXY[@]}"; do
    purple "正在通过代理 ${proxy:-直连} 下载 Xray-core..."
    if wget -qO "${WORK_DIR}/${SERVER_NAME}.zip" "${proxy}${XRAY_URL_PATH}"; then
      success=true
      break
    fi
  done
  if [ "$success" = false ]; then
    red "Xray-core 下载失败，请检查网络或更换代理！"
    exit 1
  fi

  # 循环下载 Argo
  success=false
  for proxy in "${GITHUB_PROXY[@]}"; do
    purple "正在通过代理 ${proxy:-直连} 下载 Cloudflared-Argo..."
    if wget -qO "${WORK_DIR}/argo" "${proxy}${ARGO_URL_PATH}"; then
      success=true
      break
    fi
  done
  if [ "$success" = false ]; then
    red "Cloudflared-Argo 下载失败，请检查网络或更换代理！"
    exit 1
  fi
  
  unzip -q -o "${WORK_DIR}/${SERVER_NAME}.zip" -d "${WORK_DIR}/" || true
  # 将解压出来的原生 xray 改名为我们专属的守护进程名，实现彻底物理分离
  mv "${WORK_DIR}/xray" "${WORK_DIR}/${SERVER_NAME}" 2>/dev/null || true
  chmod +x "${WORK_DIR}/${SERVER_NAME}" "${WORK_DIR}/argo"
  rm -rf "${WORK_DIR}/${SERVER_NAME}.zip" "${WORK_DIR}/geosite.dat" "${WORK_DIR}/geoip.dat" "${WORK_DIR}/README.md" "${WORK_DIR}/LICENSE"

  iptables -F >/dev/null 2>&1 || true
  iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
  iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
  iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
  command -v ip6tables &>/dev/null && { ip6tables -F >/dev/null 2>&1 || true; ip6tables -P INPUT ACCEPT >/dev/null 2>&1 || true; }

  rebuild_xray_config
}

main_systemd_services() {
  cat <<EOF > /etc/systemd/system/${XRAY_SERVICE_NAME}.service
[Unit]
Description=Xray Engine Mix Daemon Service
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$WORK_DIR/$SERVER_NAME run -c $CONFIG_DIR
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF > /etc/systemd/system/${ARGO_SERVICE_NAME}.service
[Unit]
Description=Cloudflare Argo Tunnel Mix Dynamic Backdoor
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$WORK_DIR/argo tunnel --url http://localhost:$ARGO_PORT --no-autoupdate --edge-ip-version auto --protocol http2
StandardOutput=append:$WORK_DIR/argo.log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  if [[ -f /etc/centos-release ]]; then
    yum install -y chrony >/dev/null 2>&1 || true
    systemctl start chronyd >/dev/null 2>&1 || true
    systemctl enable chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    yum update -y ca-certificates >/dev/null 2>&1 || true
  fi

  echo "0 0" > /proc/sys/net/ipv4/ping_group_range || true
  systemctl daemon-reload
  systemctl enable ${XRAY_SERVICE_NAME} >/dev/null 2>&1 || true
  systemctl restart ${XRAY_SERVICE_NAME} >/dev/null 2>&1 || true
  systemctl enable ${ARGO_SERVICE_NAME} >/dev/null 2>&1 || true
  systemctl restart ${ARGO_SERVICE_NAME} >/dev/null 2>&1 || true
}

alpine_openrc_services() {
  cat <<EOF > /etc/init.d/${XRAY_SERVICE_NAME}
#!/sbin/openrc-run
description="Xray OpenRC Mix Service"
command="${WORK_DIR}/${SERVER_NAME}"
command_args="run -c ${CONFIG_DIR}"
command_background=true
pidfile="/var/run/${XRAY_SERVICE_NAME}.pid"
EOF

  cat <<EOF > /etc/init.d/${ARGO_SERVICE_NAME}
#!/sbin/openrc-run
description="Cloudflare Tunnel OpenRC Mix Service"
command="/bin/sh"
command_args="-c '${WORK_DIR}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 > ${WORK_DIR}/argo.log 2>&1'"
command_background=true
pidfile="/var/run/${ARGO_SERVICE_NAME}.pid"
EOF

  chmod +x /etc/init.d/${XRAY_SERVICE_NAME} /etc/init.d/${ARGO_SERVICE_NAME}
  rc-update add ${XRAY_SERVICE_NAME} default >/dev/null 2>&1 || true
  rc-update add ${ARGO_SERVICE_NAME} default >/dev/null 2>&1 || true
}

# =========================================================
# 6. 节点订阅与流媒体更新分发中心
# =========================================================
get_info() {  
  clear
  local ip=$(get_realip)
  local argodomain=""
  
  if [[ -f "${WORK_DIR}/argo.log" ]]; then
    for i in {1..5}; do
      purple "正在捕捉安全穿透网关防护隧道 [第 $i 次尝试]..."
      argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${WORK_DIR}/argo.log")
      [[ -n "$argodomain" ]] && break
      sleep 2
    done
  else
    restart_argo
    sleep 5
    argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${WORK_DIR}/argo.log")
  fi

  [[ -z "$argodomain" ]] && { red "警告：未能在日志内抓取到分配的公网临时隧道链接！"; return; }

  green "\n最新穿透域名 (ArgoDomain)：${PURPLE}$argodomain${RE}\n"
  if [[ "$OUTBOUND_MODE" = "socks5" ]]; then
    green "全局出口链条：${PURPLE}SOCKS5 Proxy (${SOCKS5_HOST}:${SOCKS5_PORT})${RE}"
  else
    green "全局出口链条：${PURPLE}直连 (Direct Network)${RE}\n"
  fi

  cat <<EOF > "${WORK_DIR}/url.txt"
vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#$HOSTNAME-vless-Argo

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${HOSTNAME}-vmess-Argo\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64 -w0)
EOF

  echo ""
  while IFS= read -r line; do echo -e "${PURPLE}$line"; done < "${WORK_DIR}/url.txt"
  base64 -w0 "${WORK_DIR}/url.txt" > "${WORK_DIR}/sub.txt" 2>/dev/null || true
  echo ""
}

change_argo_domain() {
  local ArgoDomain="$1"
  [[ -z "$ArgoDomain" ]] && return 1

  sed -i "s/sni=[^&]*/sni=$ArgoDomain/g; s/host=[^&]*/host=$ArgoDomain/g" "${WORK_DIR}/url.txt"
  local content=$(cat "$CLIENT_DIR")
  local vmess_urls=$(grep -o 'vmess://[^ ]*' "$CLIENT_DIR" || echo "")

  for vmess_url in $vmess_urls; do
    local encoded_vmess="${vmess_url#vmess://}"
    local decoded_vmess=$(echo "$encoded_vmess" | base64 -d 2>/dev/null)
    if [[ -n "$decoded_vmess" ]]; then
      local updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
      local encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
      content=$(echo "$content" | sed "s|$vmess_url|vmess://$encoded_updated_vmess|")
    fi
  done

  echo "$content" > "$CLIENT_DIR"
  base64 -w0 "${WORK_DIR}/url.txt" > "${WORK_DIR}/sub.txt" 2>/dev/null || true
  
  clear
  green "节点穿透地址同步更新成功："
  while IFS= read -r line; do echo -e "${PURPLE}$line"; done < "$CLIENT_DIR"
}

get_quick_tunnel() {
  restart_argo
  yellow "正在重置异步安全隧道，请等待 3 秒内环境重刷...\n"
  sleep 3
  local get_argodomain=""
  for i in {1..5}; do
    get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${WORK_DIR}/argo.log")
    [[ -n "$get_argodomain" ]] && break
    sleep 2
  done
  if [[ -n "$get_argodomain" ]]; then
    green "重新生成的动态临时域名：$get_argodomain"
    change_argo_domain "$get_argodomain"
  else
    red "未获取到有效的穿透连接。"
  fi
}

# =========================================================
# 7. 服务运行控制机制 (Xray & Argo)
# =========================================================
start_xray() {
  yellow "正在启动 Xray 核心独立服务..."
  if is_alpine; then rc-service ${XRAY_SERVICE_NAME} start; else systemctl start ${XRAY_SERVICE_NAME}; fi
  green "服务启动命令完成"
}

stop_xray() {
  yellow "正在停止 Xray 核心独立服务..."
  if is_alpine; then rc-service ${XRAY_SERVICE_NAME} stop; else systemctl stop ${XRAY_SERVICE_NAME}; fi
  green "服务关闭命令完成"
}

restart_xray() {
  yellow "正在重启 Xray 核心独立服务..."
  if is_alpine; then rc-service ${XRAY_SERVICE_NAME} restart; else systemctl daemon-reload && systemctl restart ${XRAY_SERVICE_NAME}; fi
  green "服务重启命令完成"
}

start_argo() {
  yellow "正在启动 Argo 隧道独立守护进程..."
  if is_alpine; then rc-service ${ARGO_SERVICE_NAME} start; else systemctl start ${ARGO_SERVICE_NAME}; fi
}

stop_argo() {
  yellow "正在关闭 Argo 隧道独立守护进程..."
  if is_alpine; then rc-service ${ARGO_SERVICE_NAME} stop; else systemctl stop ${ARGO_SERVICE_NAME}; fi
}

restart_argo() {
  yellow "正在重启 Argo 隧道独立组件..."
  rm -f "${WORK_DIR}/argo.log"
  if is_alpine; then rc-service ${ARGO_SERVICE_NAME} restart; else systemctl daemon-reload && systemctl restart ${ARGO_SERVICE_NAME}; fi
}

uninstall_xray() {
  yellow "开始彻底卸载 Xray-Argo ..."

  if is_alpine; then
    rc-service ${XRAY_SERVICE_NAME} stop >/dev/null 2>&1 || true
    rc-service ${ARGO_SERVICE_NAME} stop >/dev/null 2>&1 || true
    rc-update del ${XRAY_SERVICE_NAME} default >/dev/null 2>&1 || true
    rc-update del ${ARGO_SERVICE_NAME} default >/dev/null 2>&1 || true
    rm -f /etc/init.d/${XRAY_SERVICE_NAME} /etc/init.d/${ARGO_SERVICE_NAME}
  else
    systemctl stop ${XRAY_SERVICE_NAME} ${ARGO_SERVICE_NAME} >/dev/null 2>&1 || true
    systemctl disable ${XRAY_SERVICE_NAME} ${ARGO_SERVICE_NAME} >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/${XRAY_SERVICE_NAME}.service /etc/systemd/system/${ARGO_SERVICE_NAME}.service
    systemctl daemon-reload
  fi

  rm -rf "${WORK_DIR}" /usr/bin/2go

  green "Xray-Argo 已彻底卸载完成。"
}

create_shortcut() {
  cat <<EOF > "$WORK_DIR/2go.sh"
#!/usr/bin/env bash
bash <(curl -sL https://raw.githubusercontent.com/iu683/uu/main/aa.sh) \$1
EOF
  chmod +x "$WORK_DIR/2go.sh"
  ln -sf "$WORK_DIR/2go.sh" /usr/bin/2go
  [[ -s /usr/bin/2go ]] && green "快捷特权全局系统指令 '2go' 创建成功！" || red "软连接构建失效。"
}
change_hosts() {
  echo "0 0" > /proc/sys/net/ipv4/ping_group_range || true
  sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts || true
  sed -i '2s/.*/::1         localhost/' /etc/hosts || true
}

check_nodes() {
  local xray_exist
  check_xray && xray_exist=$? || xray_exist=$?
  if [[ "$xray_exist" -ne 2 && -f "${WORK_DIR}/url.txt" ]]; then
    while IFS= read -r line; do purple "$line"; done < "${WORK_DIR}/url.txt"
    if [[ "$OUTBOUND_MODE" = "socks5" ]]; then
      green "\n当前出口：远端 SOCKS5 -> (${SOCKS5_HOST}:${SOCKS5_PORT})\n"
    else
      green "\n当前出口：直连\n"
    fi
  else
    yellow "检测到核心数据盘缺失，请先安装节点组件"
  fi
}

# =========================================================
# 8. 全新追加：运行日志与诊断调度引擎
# =========================================================
view_logs() {
  clear
  green "================================="
  green "       Xray-Argo 日志诊断管理    "
  green "================================="
  green " 1. 实时跟踪查看 Xray  (按 Ctrl+C 退出)"
  green " 2. 实时跟踪查看 Argo  (按 Ctrl+C 退出)"
  green " 3. 清理系统内日志缓存"
  purple " 0. 返回上层菜单"
  green "================================="
  local log_choice
  reading "请输入选项: " log_choice

  case "$log_choice" in
    1)
      green "正在呼叫 Xray 内核诊断实时流 (退出请按 Ctrl + C)..."
      sleep 1
      if is_alpine; then
        tail -f /var/log/messages 2>/dev/null || grep "${XRAY_SERVICE_NAME}" /var/log/messages || true
      else
        journalctl -u ${XRAY_SERVICE_NAME}.service -f || true
      fi
      ;;
    2)
      green "正在透视 Cloudflare Tunnel 穿透日志流 (退出请按 Ctrl + C)..."
      sleep 1
      if [[ -f "${WORK_DIR}/argo.log" ]]; then
        tail -f "${WORK_DIR}/argo.log" || true
      else
        red "未发现本地 Argo 运行日志记录。"
      fi
      ;;
    3)
      if [[ -f "${WORK_DIR}/argo.log" ]]; then
        echo "" > "${WORK_DIR}/argo.log"
        green "本地持久化临时日志已清空！"
      fi
      if ! is_alpine && command -v journalctl &>/dev/null; then
        journalctl --vacuum-time=1s >/dev/null 2>&1 || true
        systemctl restart systemd-journald >/dev/null 2>&1 || true
        green "Systemd 核心日志垃圾清理完毕。"
      fi
      ;;
    0) return 0 ;;
    *) red "输入不匹配。" ;;
  esac
}

# =========================================================
# 9. 分层抽样功能多重控制面板子菜单
# =========================================================
manage_xray_menu() {
  clear
  green "================================="
  green "         Xray 核心管理面板      "
  green "================================="
  green " 1. 启动 Xray "
  green " 2. 停止 Xray "
  green " 3. 重启 Xray "
  purple " 0. 返回主菜单"
  green "================================="
  local cx
  reading "请输入选项: " cx
  case "${cx}" in
    1) start_xray ;;  
    2) stop_xray ;;
    3) restart_xray ;;
    *) return 0 ;;
  esac
}

manage_argo_menu() {
  local argo_exist
  check_argo && argo_exist=$? || argo_exist=$?
  if [[ "$argo_exist" -eq 2 ]]; then
    yellow "系统检测到 Argo 未安装，拒绝调度子面板！"
    sleep 15; return
  fi

  clear
  green "================================="
  green "       Argo 隧道管理面板         "
  green "================================="
  green " 1. 启动Argo隧道"
  green " 2. 停止Argo隧道"
  green " 3. 添加Argo固定隧道"
  green " 4. 切换回Argo临时隧道"
  green " 5. 重新获取Argo临时域名"
  purple " 0. 返回主菜单"
  green "================================="
  local ca
  reading "请输入选项: " ca
  case "${ca}" in
    1) start_argo ;;
    2) stop_argo ;; 
    3)
      clear
      yellow "\n固定隧道可为 Json 文件体或 Token 字符集，端口映射底层固定为 ${ARGO_PORT} 端口。官方Json隧道获取路径：https://fscarmen.cloudflare.now.cc\n"
      local argo_domain argo_auth
      reading "请输入你的绑定的独立公网域名: " argo_domain
      [[ -z "$argo_domain" ]] && { red "域名无效"; return; }
      reading "请输入您的专属密钥串 (Token/Json 文本均匹配): " argo_auth
      
      if [[ $argo_auth =~ TunnelSecret ]]; then
        echo "$argo_auth" > "${WORK_DIR}/tunnel.json"
        cat << EOF > "${WORK_DIR}/tunnel.yml"
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${WORK_DIR}/tunnel.json
protocol: http2
ingress:
  - hostname: $argo_domain
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        if is_alpine; then
          sed -i "/^command_args=/c\\command_args=\"-c '/etc/xray_argo_mix/argo tunnel --edge-ip-version auto --config /etc/xray_argo_mix/tunnel.yml run 2>&1'\"" /etc/init.d/${ARGO_SERVICE_NAME}
        else
          sed -i "/^ExecStart=/c ExecStart=/bin/sh -c \"/etc/xray_argo_mix/argo tunnel --edge-ip-version auto --config /etc/xray_argo_mix/tunnel.yml run 2>&1\"" /etc/systemd/system/${ARGO_SERVICE_NAME}.service
        fi
        restart_argo
        change_argo_domain "$argo_domain"
      elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        if is_alpine; then
          sed -i "/^command_args=/c\\command_args=\"-c '/etc/xray_argo_mix/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/${ARGO_SERVICE_NAME}
        else
          sed -i "/^ExecStart=/c ExecStart=/bin/sh -c \"/etc/xray_argo_mix/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1\"" /etc/systemd/system/${ARGO_SERVICE_NAME}.service
        fi
        restart_argo
        change_argo_domain "$argo_domain"
      else
        yellow "输入的数据链无法被正常拆解匹配，终止操作！"
      fi
      ;; 
    4)
      if is_alpine; then alpine_openrc_services; else main_systemd_services; fi
      get_quick_tunnel
      ;; 
    5)  
      local is_dynamic=0
      if is_alpine; then
        grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/${ARGO_SERVICE_NAME} && is_dynamic=1
      else
        grep -q "ExecStart=.*--url http://localhost:${ARGO_PORT}" /etc/systemd/system/${ARGO_SERVICE_NAME}.service && is_dynamic=1
      fi

      if [[ "$is_dynamic" -eq 1 ]]; then
        get_quick_tunnel
      else
        yellow "当前您正在运行固定域名的高级网关，禁止申请下发临时域名！"
      fi 
      ;; 
    *) return 0 ;;
  esac
}

update_core() {
  local xray_exist
  check_xray && xray_exist=$? || xray_exist=$?
  if [[ "$xray_exist" -eq 2 ]]; then
    yellow "未检测到已安装的组件，请先选择选项 1 进行基础安装！"
    return 1
  fi

  clear
  yellow "开始执行内核无损升级流程..."
  yellow "正在安全停止现有服务以便替换二进制文件..."
  stop_argo
  stop_xray

  # 临时备份现有配置以保万全
  [[ -f "${CONFIG_DIR}" ]] && cp "${CONFIG_DIR}" "${CONFIG_DIR}.bak"
  [[ -f "${OUTBOUND_ENV_FILE}" ]] && cp "${OUTBOUND_ENV_FILE}" "${OUTBOUND_ENV_FILE}.bak"

  # 调用安装下载逻辑拉取最新二进制
  if install_xray; then
    # 恢复原配置防丢失
    [[ -f "${CONFIG_DIR}.bak" ]] && mv "${CONFIG_DIR}.bak" "${CONFIG_DIR}"
    [[ -f "${OUTBOUND_ENV_FILE}.bak" ]] && mv "${OUTBOUND_ENV_FILE}.bak" "${OUTBOUND_ENV_FILE}"
    
    # 重新载入环境配置并刷新
    load_outbound_env
    rebuild_xray_config
    
    yellow "正在重新启动升级后的核心服务..."
    start_xray
    start_argo
    green "内核无损升级成功！所有配置、UUID及隧道设置均未受影响。"
  else
    red "升级过程中下载失败，正在恢复原服务..."
    [[ -f "${CONFIG_DIR}.bak" ]] && mv "${CONFIG_DIR}.bak" "${CONFIG_DIR}"
    [[ -f "${OUTBOUND_ENV_FILE}.bak" ]] && mv "${OUTBOUND_ENV_FILE}.bak" "${OUTBOUND_ENV_FILE}"
    start_xray
    start_argo
  fi
}

# =========================================================
# 10. 系统控制核心总线大厅
# =========================================================

menu() {
  while true; do
    local xray_status_view argo_status_view out_view
    xray_status_view=$(get_xray_status_msg)
    argo_status_view=$(get_argo_status_msg)
    
    if [[ "$OUTBOUND_MODE" = "socks5" ]]; then
      out_view="${YELLOW}SOCKS5(${SOCKS5_HOST}:${SOCKS5_PORT})${RE}"
    else
      out_view="${GREEN}直连出口${RE}"
    fi

    clear
    echo -e "${GREEN}=================================${RE}"
    echo -e "${GREEN}       Xray-Argo 管理面板         ${RE}"
    echo -e "${GREEN}=================================${RE}"
    echo -e "${GREEN} Xray 状态 :${RE} $xray_status_view"
    echo -e "${GREEN} Argo 隧道 :${RE} $argo_status_view"
    echo -e "${GREEN} Proxy模式 :${RE} $out_view"
    echo -e "${GREEN} Argo 端口 :${RE} ${YELLOW}${ARGO_PORT}${RE}"
    echo -e "${GREEN}=================================${RE}"
    echo -e " ${GREEN}1. 安装 Xray-Argo${RE}"
    echo -e " ${GREEN}2. 更新 Xray-Argo${RE}"
    echo -e " ${GREEN}3. 卸载 Xray-Argo${RE}"
    echo -e " ${GREEN}4. Xray状态管理${RE}"
    echo -e " ${GREEN}5. Argo隧道管理${RE}"
    echo -e " ${GREEN}6. 配置Socks5出口${RE}"
    echo -e " ${GREEN}7. 查看日志${RE}"
    echo -e " ${GREEN}8. 查看节点配置${RE}"
    echo -e " ${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=================================${RE}"
    
    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "${choice}" in
      1)  
        local checked
        check_xray && checked=$? || checked=$?
        if [[ "$checked" -eq 0 ]]; then
          yellow "检测到您的隔离实例已经部署，请勿重复操作！"
        else
          manage_packages install jq unzip iptables openssl coreutils lsof
          install_xray
          if ! is_alpine; then 
            main_systemd_services
          else 
            alpine_openrc_services
            change_hosts
            rc-service ${XRAY_SERVICE_NAME} restart >/dev/null 2>&1 || rc-service ${XRAY_SERVICE_NAME} start >/dev/null 2>&1
            rc-service ${ARGO_SERVICE_NAME} restart >/dev/null 2>&1 || rc-service ${ARGO_SERVICE_NAME} start >/dev/null 2>&1
          fi
          sleep 2
          save_outbound_env; get_info; create_shortcut
        fi
        ;;
      2) update_core ;;
      3) uninstall_xray ;;
      4) manage_xray_menu ;;
      5) manage_argo_menu ;;
      6) configure_socks5_outbound ;;
      7) view_logs ;;
      8) check_nodes ;;
      0) exit 0 ;;
      *) red "输入错误，请重试！" ;;
    esac
    pause
  done
}

menu "$@"
