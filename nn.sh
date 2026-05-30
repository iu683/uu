#!/usr/bin/env bash
#
# 多后端自动适配 Alpine Linux Socks5 管理面板 
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -e
export LANG=zh_CN.UTF-8

# 基础目录与硬编码配置
WORKDIR="${HOME:-/root}/Socks5"
readonly PID_FILE="${WORKDIR}/s5.pid"
readonly META_FILE="${WORKDIR}/meta.env"
readonly CONFIG_S5="${WORKDIR}/config.json"
readonly CONFIG_3PROXY="${WORKDIR}/3proxy.cfg"

DEFAULT_PORT=1080
PREFERRED_IMPLS=("microsocks" "3proxy" "s5")

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
  type -P "$1" > /dev/null 2>&1
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -r -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

ensure_workdir() {
  mkdir -p "${WORKDIR}"
  chmod 700 "${WORKDIR}"
}

random_port() {
  # 兼容 Alpine (BusyBox) 的 awk 随机数发生器
  awk 'BEGIN{srand(); print int(rand()*(60000-20000+1))+20000}'
}

random_user() {
  echo "s5_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6)"
}

random_pass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "s5pass123"
}

get_best_ip() {
  local ip
  for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
    ip=$(curl -s --max-time 5 "$svc" || wget -T 5 -qO- "$svc" || true)
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "127.0.0.1"
}

urlencode() {
  local s="$1"
  if has_command python3; then
    python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=''))" "$s"
  else
    # 纯 shell 托底转换
    echo -n "$s" | awk 'BEGIN {
      for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i
    }
    {
      encoded = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[a-zA-Z0-9_.~-]/) encoded = encoded c
        else encoded = encoded sprintf("%%%02X", ord[c])
      }
      print encoded
    }'
  fi
}

# =========================================================
# 3. 后端组件检测与多包管理器自动安装
# =========================================================
detect_existing_impl() {
  for impl in "${PREFERRED_IMPLS[@]}"; do
    if has_command "${impl}"; then echo "${impl}"; return 0; fi
  done
  echo ""
}

try_install_package() {
  local pkg_name="$1"
  info "正在尝试通过 apk 包管理器部署相关组件: ${pkg_name}..."
  if has_command apk; then
    apk update >/dev/null 2>&1
    apk add --no-cache "${pkg_name}" >/dev/null 2>&1 && return 0
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
nserver 1.1.1.1
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

# 写入当前脚本的 PID 以便 Alpine 精准追踪状态
echo "$$" > "${WORKDIR}/s5.pid"

case "$BIN_TYPE" in
  3proxy)     exec 3proxy "${WORKDIR}/3proxy.cfg" ;;
  s5)         exec s5 -c "${WORKDIR}/config.json" ;;
  microsocks) exec microsocks -i 0.0.0.0 -p "$PORT" -u "$USERNAME" -P "$PASSWORD" ;;
  *)          echo "未知的 Socks5 底层实现引擎类型: $BIN_TYPE"; exit 1 ;;
esac
EOF
  chmod +x "${WORKDIR}/start.sh"
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

get_runtime_pid() {
  local saved_pid=""
  if [ -f "${PID_FILE}" ]; then
    saved_pid=$(cat "${PID_FILE}" 2>/dev/null)
  fi
  # 验证 PID 对应进程是否依然存活，且属于当前的代理后端
  if [[ -n "$saved_pid" ]] && kill -0 "$saved_pid" 2>/dev/null; then
    echo "$saved_pid"
  else
    # 模糊兜底扫描
    local fallback_pid=""
    fallback_pid=$(ps -ef 2>/dev/null | grep -E 'start.sh|microsocks|3proxy|s5 -c' | grep -v grep | awk '{print $1}' | head -n 1)
    echo "$fallback_pid"
  fi
}

check_port_listening() {
  local check_port=$1
  if [[ -n "$check_port" ]]; then
    netstat -an 2>/dev/null | grep -E "[:\.]${check_port} " | grep -i "listen"
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

  # 强杀历史进程
  stop_service_internal

  # 挂载 Alpine 专属后台独立守护池中运行
  nohup "${WORKDIR}/start.sh" >/dev/null 2>&1 &
  sleep 1.5

  local active_pid
  active_pid=$(get_runtime_pid)
  local is_listen
  is_listen=$(check_port_listening "$PORT")

  if [[ -n "$active_pid" || -n "$is_listen" ]]; then
    info "Socks5 核心服务配置并启动成功！"
  else
    error "Socks5 服务启动失败，请检查端口是否冲突或查看本地进程日志。"
  fi
  showconf
}

stop_service_internal() {
  local active_pid
  active_pid=$(get_runtime_pid)
  if [[ -n "$active_pid" ]]; then
    kill -9 "$active_pid" >/dev/null 2>&1 || true
  fi
  # 深度强杀可能残留的分支后端进程
  pkill -9 -f "${WORKDIR}/start.sh" >/dev/null 2>&1 || true
  pkill -9 -x microsocks >/dev/null 2>&1 || true
  pkill -9 -x 3proxy >/dev/null 2>&1 || true
  pkill -9 -x s5 >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
}

inst_socks5() {
  ensure_workdir
  
  local exist_impl
  exist_impl="$(detect_existing_impl || true)"
  if [ -n "${exist_impl}" ]; then
    info "当前 Alpine 系统已存在可用组件实现: ${YELLOW}${exist_impl}${RESET}"
    BIN_TYPE="${exist_impl}"
  else
    warn "未检测到内置的代理实现，开始尝试自动拉取 Alpine 原生轻量组件..."
    if try_install_package "microsocks"; then
      BIN_TYPE="microsocks"
    elif try_install_package "3proxy"; then
      BIN_TYPE="3proxy"
    else
      error "未能通过 apk 自动部署代理组件。请执行 'apk add microsocks' 后重新运行此脚本。"
      return 1
    fi
  fi

  local rand_user rand_pass rand_port
  rand_user="$(random_user)"
  rand_pass="$(random_pass)"
  rand_port=$(random_port)

  echo "---------------------------------------------"
  while true; do
    read -rp "👉 请输入监听端口 (默认随机: ${rand_port}): " input_port
    PORT=${input_port:-$rand_port}
    if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
      warn "端口输入无效，请输入 1-65535 之间的数字。"
      continue
    fi
    # 适配 Alpine (BusyBox) 的网络占用排查
    if [[ -n $(check_port_listening "$PORT") ]]; then
      error "${PORT} 端口已经被其他程序占用，请更换端口重试。"
      rand_port=$(random_port)
      continue
    fi
    break
  done

  read -rp "👉 请设置用户名 (默认随机: ${rand_user}): " input_user
  USERNAME=${input_user:-$rand_user}

  read -rp "👉 请设置密码 (默认随机: ${rand_pass}): " input_pass
  PASSWORD=${input_pass:-$rand_pass}

  write_and_start_service
}

changeconf() {
  load_meta
  if [ -z "${BIN_TYPE}" ]; then
    BIN_TYPE="$(detect_existing_impl || true)"
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
  
  while true; do
    read -rp "👉 请输入新的监听端口 [当前: ${PORT:-1080}]: " input_port
    if [ -n "$input_port" ]; then
      if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
        if [[ "$input_port" != "$PORT" && -n $(check_port_listening "$input_port") ]]; then
          error "${input_port} 端口已被其他程序占用，请更换端口。"
          continue
        fi
        PORT="${input_port}"
      else
        warn "输入端口格式不合法，保留原端口不变。"
      fi
    fi
    break
  done

  read -rp "👉 请设置新的用户名 [当前: ${USERNAME:-unset}]: " input_user
  USERNAME=${input_user:-$USERNAME}

  read -rp "👉 请设置新的密码 [当前: ${PASSWORD:-unset}]: " input_pass
  PASSWORD=${input_pass:-$PASSWORD}

  write_and_start_service
}

uninstall_socks5() {
  warn "即将从当前 Alpine 系统中彻底卸载并清理 Socks5 服务..."
  stop_service_internal
  rm -rf "${WORKDIR}"
  info "Socks5 全套配置文件及后台进程已经彻底移除！"
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
    
    local status_display active_pid is_listen
    active_pid=$(get_runtime_pid)
    is_listen=$(check_port_listening "$PORT")

    if [[ -n "$active_pid" || -n "$is_listen" ]]; then
      status_display="${GREEN}● 运行中 (Alpine 独立进程池)${RESET}"
    else
      status_display="${RED}● 未运行${RESET}"
    fi

    local port_display="${PORT:- -}"
    local engine_display="${BIN_TYPE:-未检测到底层安装}"

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     Socks5 Alpine 管理面板     ${RESET}"
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
        if [[ -n $(get_runtime_pid) || -n $(check_port_listening "$PORT") ]]; then
          yellow_echo "Socks5 服务已经在运行中。"
        else
          nohup "${WORKDIR}/start.sh" >/dev/null 2>&1 &
          sleep 1
          info "进程已在后台独立进程池中拉起！"
        fi
        pause ;;
      5)
        stop_service_internal
        info "后台代理程序已终止！"
        pause ;;
      6)
        stop_service_internal
        sleep 1
        nohup "${WORKDIR}/start.sh" >/dev/null 2>&1 &
        sleep 1
        info "后台独立进程已重载刷新！"
        pause ;;
      8) showconf; pause ;;
      0) exit 0 ;;
      *) error "未识别的无效指令，请重新进行选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
