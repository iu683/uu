#!/usr/bin/env bash
#
# 多后端自动适配 Socks5 管理面板 
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
WORKDIR="${HOME:-/root}/Socks5"
readonly PID_FILE="${WORKDIR}/s5.pid"
readonly META_FILE="${WORKDIR}/meta.env"
readonly CONFIG_S5="${WORKDIR}/config.json"
readonly CONFIG_3PROXY="${WORKDIR}/3proxy.cfg"
readonly SERVICE_FILE="/etc/systemd/system/s5.service"

DEFAULT_PORT=1080
PREFERRED_IMPLS=("s5" "3proxy" "microsocks" "ss5" "danted" "sockd")

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 官方原生底层工具函数与网络环境探测
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
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

ensure_workdir() {
  mkdir -p "${WORKDIR}"
  chmod 700 "${WORKDIR}"
}

random_port() {
  shuf -i 20000-60000 -n 1
}

random_user() {
  echo "s5_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6)"
}

random_pass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "s5pass123"
}

get_best_ip() {
  local ip
  for svc in "https://icanhazip.com" "https://ifconfig.me" "https://ipinfo.io/ip" "https://4.ipw.cn"; do
    ip=$(curl -s --max-time 5 "$svc" || true)
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  if has_command ip; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  fi

  echo "127.0.0.1"
}

urlencode() {
  local s="$1"
  if has_command python3; then
    python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=''))" "$s"
  elif has_command python; then
    python -c "import sys,urllib as u; print(u.quote(sys.argv[1]))" "$s"
  else
    printf '%s' "$s"
  fi
}

# =========================================================
# 3. 后端组件检测与多包管理器自动安装
# =========================================================
detect_existing_impl() {
  for impl in "${PREFERRED_IMPLS[@]}"; do
    case "${impl}" in
      s5|3proxy|microsocks|ss5)
        if has_command "${impl}"; then echo "${impl}"; return 0; fi
        ;;
      danted|sockd)
        if has_command sockd || has_command danted; then echo "danted"; return 0; fi
        ;;
    esac
  done
  echo ""
}

try_install_package() {
  local pkg_name="$1"
  info "正在尝试通过包管理器部署相关组件: ${pkg_name}..."
  if has_command apt-get; then
    apt-get update -y && apt-get install -y "${pkg_name}" && return 0
  elif has_command dnf; then
    dnf install -y "${pkg_name}" && return 0
  elif has_command yum; then
    yum install -y "${pkg_name}" && return 0
  elif has_command apk; then
    apk add --no-cache "${pkg_name}" && return 0
  elif has_command pacman; then
    pacman -Sy --noconfirm "${pkg_name}" && return 0
  fi
  return 1
}

# =========================================================
# 4. 核心配置文件与守护进程服务生成
# =========================================================
generate_backend_config() {
  case "${BIN_TYPE}" in
    3proxy)
      cat << EOF > "${CONFIG_3PROXY}"
daemon
maxconn 100
nserver 8.8.8.8
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
users ${USERNAME}:CL:${PASSWORD}
auth strong
allow ${USERNAME}
socks -p${PORT}
EOF
      chmod 600 "${CONFIG_3PROXY}"
      ;;
    s5)
      cat << EOF > "${CONFIG_S5}"
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "socks",
    "tag": "socks",
    "settings": {
      "auth": "password",
      "udp": false,
      "ip": "0.0.0.0",
      "userLevel": 0,
      "accounts": [{"user": "${USERNAME}", "pass": "${PASSWORD}"}]
    }
  }],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
EOF
      chmod 600 "${CONFIG_S5}"
      ;;
  esac
}

create_start_script() {
  cat << 'EOF' > "${WORKDIR}/start.sh"
#!/usr/bin/env bash
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${WORKDIR}/meta.env" ]; then
  source "${WORKDIR}/meta.env"
else
  echo "核心环境配置文件 meta.env 丢失"
  exit 1
fi

case "$BIN_TYPE" in
  3proxy)     exec 3proxy "${WORKDIR}/3proxy.cfg" ;;
  s5)         exec s5 -c "${WORKDIR}/config.json" ;;
  microsocks) exec microsocks -i 0.0.0.0 -p "$PORT" -u "$USERNAME" -P "$PASSWORD" ;;
  ss5)        exec ss5 -u "$USERNAME:$PASSWORD" -p "$PORT" ;;
  *)          echo "未知的 Socks5 底层实现引擎类型: $BIN_TYPE"; exit 1 ;;
esac
EOF
  chmod +x "${WORKDIR}/start.sh"
}

create_service() {
  cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=Socks5 Multi-Backend Service
After=network.target network-online.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable s5 >/dev/null 2>&1 || true
  fi
}

save_meta() {
  cat << EOF > "${META_FILE}"
PORT='${PORT}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
BIN_TYPE='${BIN_TYPE}'
EOF
  chmod 600 "${META_FILE}"
}

load_meta() {
  if [ -f "${META_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
  else
    PORT=""
    USERNAME=""
    PASSWORD=""
    BIN_TYPE=""
  fi
}

# =========================================================
# 5. 主流程控制模块（安装、更新、修改、卸载）
# =========================================================
write_and_start_service() {
  ensure_workdir
  save_meta
  generate_backend_config
  create_start_script
  create_service

  if has_command systemctl; then
    systemctl restart s5 >/dev/null 2>&1 || true
    sleep 1.5
    if systemctl is-active --quiet s5 2>/dev/null; then
      info "Socks5 核心服务配置并启动成功！"
    else
      error "Socks5 服务启动失败，请运行 'journalctl -u s5 -f' 查看错误日志。"
    fi
  else
    pkill -f "${WORKDIR}/start.sh" || true
    "${WORKDIR}/start.sh" >/dev/null 2>&1 &
    info "非 systemd 环境，守护进程已挂载至后台进程池中运行。"
  fi
  showconf
}

inst_socks5() {
  ensure_workdir
  
  # 检测底层引擎依赖
  local exist_impl
  exist_impl="$(detect_existing_impl || true)"
  if [ -n "${exist_impl}" ]; then
    info "当前系统已存在可用组件实现: ${YELLOW}${exist_impl}${RESET} (将直接适配)"
    BIN_TYPE="${exist_impl}"
  else
    warn "系统未检测到内置的代理实现，开始尝试自动拉取交叉编译依赖..."
    if try_install_package "microsocks"; then
      BIN_TYPE="microsocks"
    elif try_install_package "3proxy"; then
      BIN_TYPE="3proxy"
    else
      error "未能通过包管理器自动安装任何代理底层实现（microsocks/3proxy）。"
      error "请检查您的网络连接或手动安装其中之一后重新运行此脚本。"
      return 1
    fi
  fi

  local rand_user
  rand_user="$(random_user)"
  local rand_pass
  rand_pass="$(random_pass)"
  local rand_port
  rand_port=$(random_port)

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " input_port
  PORT=${input_port:-$rand_port}
  if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
    warn "端口输入无效，已自动回滚为随机端口: ${rand_port}"
    PORT="${rand_port}"
  fi

  read -rp "👉 请设置用户名 (默认随机: ${rand_user}): " input_user
  USERNAME=${input_user:-$rand_user}

  read -rp "👉 请设置密码 (默认随机: ${rand_pass}): " input_pass
  PASSWORD=${input_pass:-$rand_pass}

  write_and_start_service
}

changeconf() {
  load_meta
  if [ -z "${BIN_TYPE}" ]; then
    local exist_impl
    exist_impl="$(detect_existing_impl || true)"
    BIN_TYPE="${exist_impl:-}"
  fi
  if [ -z "${BIN_TYPE}" ]; then
    error "未找到有效的底层服务组件，请先执行选项 1 进行安装。"
    return 1
  fi

  clear
  echo -e "${GREEN}====== 修改 Socks5 节点配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"

  local input_port input_user input_pass
  
  read -rp "👉 请输入新的监听端口 [当前: ${PORT:-1080}]: " input_port
  if [ -n "$input_port" ]; then
    if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
      PORT="${input_port}"
    else
      warn "输入端口格式不合法，保留原端口不变。"
    fi
  fi

  read -rp "👉 请设置新的用户名 [当前: ${USERNAME:-unset}]: " input_user
  USERNAME=${input_user:-$USERNAME}

  read -rp "👉 请设置新的密码 [当前: ${PASSWORD:-unset}]: " input_pass
  PASSWORD=${input_pass:-$PASSWORD}

  write_and_start_service
}

uninstall_socks5() {
  warn "即将从当前系统中彻底卸载并清理 Socks5 服务..."

  if has_command systemctl; then
    systemctl stop s5 >/dev/null 2>&1 || true
    systemctl disable s5 >/dev/null 2>&1 || true
    if [ -f "${SERVICE_FILE}" ]; then
      rm -f "${SERVICE_FILE}"
    fi
    systemctl daemon-reload
  else
    pkill -f "${WORKDIR}/start.sh" || true
  fi

  rm -rf "${WORKDIR}"
  info "Socks5 全套配置文件及服务已经从您的系统中彻底移除！"
}

showconf() {
  load_meta
  if [ -z "${PORT}" ]; then
    error "未找到任何可用的元配置文件，请确认服务已成功初始化。"
    return 1
  fi

  local ip enc_user enc_pass enc_ip socksurl tlink
  ip="$(get_best_ip)"
  enc_user="$(urlencode "${USERNAME}")"
  enc_pass="$(urlencode "${PASSWORD}")"
  enc_ip="$(urlencode "${ip}")"

  socksurl="socks://${USERNAME}:${PASSWORD}@${ip}:${PORT}"
  tlink="https://t.me/socks?server=${enc_ip}&port=${PORT}&user=${enc_user}&pass=${enc_pass}"

  echo -e "${GREEN}====== Socks5 配置 ======${RESET}"
  echo -e "${YELLOW}● 客户端直连格式:${RESET} ${socksurl}"
  echo -e "${YELLOW}● Telegram 快捷链接:${RESET} ${tlink}"
  echo
}

# =========================================================
# 6. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  ensure_workdir

  while true; do
    clear
    load_meta
    
    local status_display
    if has_command systemctl && systemctl is-active --quiet s5 2>/dev/null; then
      status_display="${GREEN}● 运行中${RESET}"
    else
      if pkill -0 -f "${WORKDIR}/start.sh" >/dev/null 2>&1; then
        status_display="${GREEN}● 运行中 (Pidmode)${RESET}"
      else
        status_display="${RED}● 未运行${RESET}"
      fi
    fi

    local port_display="${PORT:- -}"
    local engine_display="${BIN_TYPE:-未检测到底层安装}"

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        Socks5 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status_display}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}实现   :${RESET} ${CYAN}${engine_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Socks5${RESET}"
    echo -e "${GREEN}2. 修改配置${RESET}"
    echo -e "${GREEN}3. 卸载 Socks5${RESET}"
    echo -e "${GREEN}4. 启动 Socks5${RESET}"
    echo -e "${GREEN}5. 停止 Socks5${RESET}"
    echo -e "${GREEN}6. 重启 Socks5${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看连接配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_socks5; pause ;;
      2) changeconf; pause ;;
      3) uninstall_socks5; pause ;;
      4)
        if has_command systemctl; then
          systemctl start s5 && info "服务已成功拉起！"
        else
          pkill -f "${WORKDIR}/start.sh" || true
          "${WORKDIR}/start.sh" >/dev/null 2>&1 &
          info "进程已在后台独立进程池中拉起！"
        fi
        pause ;;
      5)
        if has_command systemctl; then
          systemctl stop s5 && info "服务已成功挂起！"
        else
          pkill -f "${WORKDIR}/start.sh" && info "后台代理程序已终止！"
        fi
        pause ;;
      6)
        if has_command systemctl; then
          systemctl restart s5 && info "服务已成功完成平滑重启！"
        else
          pkill -f "${WORKDIR}/start.sh" || true
          "${WORKDIR}/start.sh" >/dev/null 2>&1 &
          info "后台独立进程已重载刷新！"
        fi
        pause ;;
      7)
        if has_command systemctl; then
          journalctl -u s5.service -n 50 --no-pager
        else
          warn "当前 Linux 环境不支持 Systemd 级集中式日志流水。"
        fi
        pause ;;
      8) showconf; pause ;;
      0) exit 0 ;;
      *) error "未识别的无效指令，请重新进行选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
