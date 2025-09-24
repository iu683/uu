#!/usr/bin/env bash
#
set -o errexit
set -o nounset
set -o pipefail

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

WORKDIR="${HOME:-/root}/.s5_manager"
PID_FILE="${WORKDIR}/s5.pid"
META_FILE="${WORKDIR}/meta.env"
CONFIG_S5="${WORKDIR}/config.json"
CONFIG_3PROXY="${WORKDIR}/3proxy.cfg"
DEFAULT_PORT=1080
DEFAULT_USER="s5user"

PREFERRED_IMPLS=("s5" "3proxy" "microsocks" "ss5" "danted" "sockd")

ensure_workdir() {
  mkdir -p "${WORKDIR}"
  chmod 700 "${WORKDIR}"
}

load_meta() {
  if [ -f "${META_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
  else
    ACCOUNTS=()
    BIN_TYPE=""
  fi
}

save_meta() {
  {
    echo "ACCOUNTS=("
    for acc in "${ACCOUNTS[@]}"; do
      echo "  \"$acc\""
    done
    echo ")"
    echo "BIN_TYPE='${BIN_TYPE}'"
  } > "${META_FILE}"
  chmod 600 "${META_FILE}"
}

prompt() {
  local prompt_text="$1"
  local default="${2:-}"
  local varname="$3"
  local input
  if [ -n "${default}" ]; then
    printf "%s [%s]: " "${prompt_text}" "${default}" > /dev/tty
  else
    printf "%s: " "${prompt_text}" > /dev/tty
  fi
  read -r input < /dev/tty || input=""
  if [ -z "${input}" ]; then
    input="${default}"
  fi
  printf -v "${varname}" "%s" "${input}"
}

random_pass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "s5pass123"
}

detect_existing_impl() {
  for impl in "${PREFERRED_IMPLS[@]}"; do
    case "${impl}" in
      s5) command -v s5 >/dev/null 2>&1 && echo "s5" && return 0 ;;
      3proxy) command -v 3proxy >/dev/null 2>&1 && echo "3proxy" && return 0 ;;
      microsocks) command -v microsocks >/dev/null 2>&1 && echo "microsocks" && return 0 ;;
      ss5) command -v ss5 >/dev/null 2>&1 && echo "ss5" && return 0 ;;
      danted|sockd) command -v sockd >/dev/null 2>&1 || command -v danted >/dev/null 2>&1 && echo "danted" && return 0 ;;
    esac
  done
  echo ""
}

try_install_3proxy() {
  echo "尝试通过包管理器安装 3proxy..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y 3proxy && return 0 || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y 3proxy && return 0 || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y 3proxy && return 0 || return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache 3proxy && return 0 || return 1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm 3proxy && return 0 || return 1
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y 3proxy && return 0 || return 1
  fi
  return 1
}

try_install_microsocks() {
  echo "尝试通过包管理器安装 microsocks..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y microsocks && return 0 || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y microsocks && return 0 || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y microsocks && return 0 || return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache microsocks && return 0 || return 1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm microsocks && return 0 || return 1
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y microsocks && return 0 || return 1
  fi
  return 1
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
  echo "127.0.0.1"
}

urlencode() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=''))" "$s"
  elif command -v python >/dev/null 2>&1; then
    python -c "import sys,urllib as u; print(u.quote(sys.argv[1]))" "$s"
  elif command -v perl >/dev/null 2>&1; then
    perl -MURI::Escape -e 'print uri_escape($ARGV[0]);' "$s"
  else
    printf '%s' "$s"
  fi
}

show_links() {
  local ip port user pass enc_user enc_pass enc_ip socksurl tlink
  ip="$(get_best_ip)"
  echo
  echo -e "${GREEN}账号连接信息:${RESET}"
  local i=1
  for acc in "${ACCOUNTS[@]}"; do
    IFS=":" read -r port user pass <<<"$acc"
    enc_user="$(urlencode "$user")"
    enc_pass="$(urlencode "$pass")"
    enc_ip="$(urlencode "$ip")"
    socksurl="socks://${user}:${pass}@${ip}:${port}"
    tlink="https://t.me/socks?server=${enc_ip}&port=${port}&user=${enc_user}&pass=${enc_pass}"
    echo "$i) $socksurl"
    echo "   Telegram: $tlink"
    i=$((i+1))
  done
  echo
}

start_by_type() {
  local type="$1"
  stop_socks
  case "${type}" in
    3proxy)
      local cfg="${CONFIG_3PROXY}"
      {
        echo "daemon"
        echo "maxconn 100"
        echo "nserver 8.8.8.8"
        echo "nserver 8.8.4.4"
        echo "timeouts 1 5 30 60 180 1800 15 60"
        for acc in "${ACCOUNTS[@]}"; do
          IFS=":" read -r port user pass <<<"$acc"
          echo "users ${user}:CL:${pass}"
          echo "auth strong"
          echo "allow ${user}"
          echo "socks -p${port}"
        done
      } > "${cfg}"
      chmod 600 "${cfg}"
      nohup 3proxy "${cfg}" >/dev/null 2>&1 &
      echo $! > "${PID_FILE}"
      ;;
    microsocks)
      for acc in "${ACCOUNTS[@]}"; do
        IFS=":" read -r port user pass <<<"$acc"
        nohup microsocks -p "${port}" -u "${user}" -P "${pass}" >/dev/null 2>&1 &
        echo $! >> "${PID_FILE}"
      done
      ;;
    s5)
      for acc in "${ACCOUNTS[@]}"; do
        IFS=":" read -r port user pass <<<"$acc"
        local cfg="${WORKDIR}/s5_${port}.json"
        cat > "${cfg}" <<EOF
{
  "inbounds": [
    {
      "port": ${port},
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "udp": false,
        "accounts": [
          {"user": "${user}", "pass": "${pass}"}
        ]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom"}
  ]
}
EOF
        nohup s5 -c "${cfg}" >/dev/null 2>&1 &
        echo $! >> "${PID_FILE}"
      done
      ;;
    *)
      echo -e "${RED}未知或未支持的实现: ${type}${RESET}"
      return 1
      ;;
  esac
  sleep 1
  if [ -s "${PID_FILE}" ]; then
    echo -e "${GREEN}已启动 ${type}${RESET}"
    show_links
    return 0
  else
    echo -e "${RED}启动失败${RESET}"
    return 1
  fi
}

stop_socks() {
  if [ -f "${PID_FILE}" ]; then
    while read -r pid; do
      kill "$pid" >/dev/null 2>&1 || true
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
  fi
  for p in s5 3proxy microsocks ss5 danted sockd; do
    pkill -x "${p}" >/dev/null 2>&1 || true
  done
}

list_accounts() {
  load_meta
  if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
    echo "暂无账号"
    return
  fi
  echo -e "${GREEN}账号列表:${RESET}"
  local i=1
  for acc in "${ACCOUNTS[@]}"; do
    IFS=":" read -r port user pass <<<"$acc"
    echo "$i) 端口: $port, 用户名: $user, 密码: $pass"
    i=$((i+1))
  done
}

add_accounts() {
  ensure_workdir
  load_meta
  prompt "要生成几个账号" "3" COUNT
  prompt "起始端口号" "${DEFAULT_PORT}" BASEPORT
  for ((i=0; i<COUNT; i++)); do
    user="s5user$((i+1))"
    pass="$(random_pass)"
    port=$((BASEPORT+i))
    ACCOUNTS+=("${port}:${user}:${pass}")
    echo "生成账号 -> 端口: $port, 用户名: $user, 密码: $pass"
  done
  save_meta
  echo -e "${GREEN}批量生成完成${RESET}"
}

delete_account() {
  ensure_workdir
  load_meta
  list_accounts
  prompt "输入要删除的编号" "" IDX
  if ! [[ "$IDX" =~ ^[0-9]+$ ]]; then
    echo "无效编号"
    return
  fi
  if [ "$IDX" -lt 1 ] || [ "$IDX" -gt "${#ACCOUNTS[@]}" ]; then
    echo "编号不存在"
    return
  fi
  unset 'ACCOUNTS[IDX-1]'
  ACCOUNTS=("${ACCOUNTS[@]}")
  save_meta
  echo -e "${YELLOW}已删除账号 ${IDX}${RESET}"
}

delete_all_accounts() {
  ensure_workdir
  load_meta
  prompt "确认要删除所有账号? 输入 y 确认" "N" CONFIRM
  if [ "$CONFIRM" != "y" ]; then
    echo "已取消"
    return
  fi
  ACCOUNTS=()
  save_meta
  echo -e "${RED}所有账号已删除${RESET}"
}

install_flow() {
  ensure_workdir
  EXIST="$(detect_existing_impl || true)"
  if [ -n "${EXIST}" ]; then
    BIN_TYPE="${EXIST}"
  else
    echo "未检测到受支持的实现，尝试安装 microsocks ..."
    if try_install_microsocks; then
      BIN_TYPE="microsocks"
    elif try_install_3proxy; then
      BIN_TYPE="3proxy"
    fi
  fi
  if [ -z "${BIN_TYPE}" ]; then
    echo -e "${RED}未能安装任何 socks5 实现${RESET}"
    return 1
  fi
  save_meta
  start_by_type "${BIN_TYPE}" || return 1
  return 0
}

status_flow() {
  ensure_workdir
  load_meta
  if [ -f "${PID_FILE}" ]; then
    echo -e "${GREEN}socks5 已运行:${RESET}"
    list_accounts
  else
    echo -e "${YELLOW}未运行${RESET}"
  fi
}

main_menu() {
  while true; do
    echo
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     Socks5 管理工具     ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}1) 安装 socks5${RESET}"
    echo -e "${GREEN}2) 启动 socks5${RESET}"
    echo -e "${GREEN}3) 停止 socks5${RESET}"
    echo -e "${GREEN}4) 批量生成账号${RESET}"
    echo -e "${GREEN}5) 查看账号列表${RESET}"
    echo -e "${GREEN}6) 删除指定账号${RESET}"
    echo -e "${GREEN}7) 删除所有账号${RESET}"
    echo -e "${GREEN}8) 状态${RESET}"
    echo -e "${GREEN}9) 退出${RESET}"
    read -r -p "$(echo -e "${GREEN}请选择 (1-9): ${RESET}")" opt < /dev/tty || opt="9"
    case "${opt}" in
      1) install_flow ;;
      2) start_by_type "${BIN_TYPE:-microsocks}" ;;
      3) stop_socks ;;
      4) add_accounts ;;
      5) list_accounts ;;
      6) delete_account ;;
      7) delete_all_accounts ;;
      8) status_flow ;;
      9) echo -e "${GREEN}退出${RESET}"; exit 0 ;;
      *) echo -e "${RED}无效选项${RESET}" ;;
    esac
  done
}

ensure_workdir
load_meta
main_menu
