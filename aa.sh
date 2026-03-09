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
SERVICE_FILE="/etc/systemd/system/s5.service"

PREFERRED_IMPLS=("s5" "3proxy" "microsocks" "ss5" "danted" "sockd")

random_port() {
  shuf -i 20000-60000 -n 1
}

ensure_workdir() {
  mkdir -p "${WORKDIR}"
  chmod 700 "${WORKDIR}"
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

save_meta() {
  cat > "${META_FILE}" <<EOF
PORT='${PORT}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
BIN_TYPE='${BIN_TYPE}'
EOF
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
      s5)
        if command -v s5 >/dev/null 2>&1; then
          echo "s5"
          return 0
        fi
        ;;
      3proxy)
        if command -v 3proxy >/dev/null 2>&1; then
          echo "3proxy"
          return 0
        fi
        ;;
      microsocks)
        if command -v microsocks >/dev/null 2>&1; then
          echo "microsocks"
          return 0
        fi
        ;;
      ss5)
        if command -v ss5 >/dev/null 2>&1; then
          echo "ss5"
          return 0
        fi
        ;;
      danted|sockd)
        if command -v sockd >/dev/null 2>&1 || command -v danted >/dev/null 2>&1; then
          echo "danted"
          return 0
        fi
        ;;
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

generate_3proxy_cfg() {
  local port="$1" user="$2" pass="$3" cfg="${CONFIG_3PROXY}"
  cat > "${cfg}" <<EOF
daemon
maxconn 100
nserver 8.8.8.8
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
users ${user}:CL:${pass}
auth strong
allow ${user}
socks -p${port}
EOF
  chmod 600 "${cfg}"
  echo "${cfg}"
}

generate_s5_json() {
  local port="$1" user="$2" pass="$3" cfg="${CONFIG_S5}"
  cat > "${cfg}" <<EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": ${port},
      "protocol": "socks",
      "tag": "socks",
      "settings": {
        "auth": "password",
        "udp": false,
        "ip": "0.0.0.0",
        "userLevel": 0,
        "accounts": [
          {
            "user": "${user}",
            "pass": "${pass}"
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF
  chmod 600 "${cfg}"
  echo "${cfg}"
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

  if command -v ip >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  fi

  if command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
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

create_service() {

cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=Socks5 Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/start.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable s5
}

create_start_script() {

cat > ${WORKDIR}/start.sh <<EOF
#!/usr/bin/env bash
source ${META_FILE}

case "\$BIN_TYPE" in
3proxy)
    exec 3proxy ${CONFIG_3PROXY}
    ;;
s5)
    exec s5 -c ${CONFIG_S5}
    ;;
microsocks)
    exec microsocks -i :: -p \$PORT -u \$USERNAME -P \$PASSWORD
    ;;
ss5)
    exec ss5 -u \$USERNAME:\$PASSWORD -p \$PORT
    ;;
*)
    echo "unknown type"
    exit 1
    ;;
esac
EOF

chmod +x ${WORKDIR}/start.sh
}

show_links() {
  local ip port user pass enc_user enc_pass enc_ip tlink socksurl
  ip="$(get_best_ip)"
  port="${PORT}"
  user="${USERNAME}"
  pass="${PASSWORD}"
  enc_user="$(urlencode "$user")"
  enc_pass="$(urlencode "$pass")"
  enc_ip="$(urlencode "$ip")"

  socksurl="socks://${user}:${pass}@${ip}:${port}"
  tlink="https://t.me/socks?server=${enc_ip}&port=${port}&user=${enc_user}&pass=${enc_pass}"

  echo
  echo -e "${GREEN}安装并启动完成:${RESET}"
  echo -e "${YELLOW}socks地址：${socksurl}${RESET}"
  echo -e "${YELLOW}Telegram快链：${tlink}${RESET}"
  echo
  read -n 1 -s -r -p "按任意键返回菜单..."
}

start_by_type() {

create_start_script
create_service

systemctl restart s5

sleep 1

if systemctl is-active --quiet s5; then
    echo -e "${GREEN}Socks5 已启动 (systemd)${RESET}"
    show_links
else
    echo -e "${RED}启动失败${RESET}"
fi
}

stop_socks() {

if systemctl list-unit-files | grep -q s5.service; then
    systemctl stop s5
fi

rm -f "${PID_FILE}" || true
}

install_flow() {
  ensure_workdir
  echo "安装/配置 socks5（交互）"

  prompt "监听端口（回车随机）" "" PORT

  if [ -z "${PORT}" ]; then
    PORT=$(random_port)
    echo "使用随机端口: ${PORT}"
  elif ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
    echo "端口输入无效，重新生成随机端口"
    PORT=$(random_port)
    echo "使用随机端口: ${PORT}"
  fi
  prompt "用户名" "${DEFAULT_USER}" USERNAME
  prompt "密码（留空则自动生成）" "" PASSWORD
  if [ -z "${PASSWORD}" ]; then
    PASSWORD="$(random_pass)"
    echo "已生成密码：${PASSWORD}"
  fi

  EXIST="$(detect_existing_impl || true)"
  if [ -n "${EXIST}" ]; then
    echo "检测到系统可用实现：${EXIST}（将尝试使用它）"
    BIN_TYPE="${EXIST}"
  else
    echo "未检测到受支持的实现，尝试安装 microsocks ..."
    if try_install_microsocks; then
      BIN_TYPE="microsocks"
      echo "已安装 microsocks"
    elif try_install_3proxy; then
      BIN_TYPE="3proxy"
      echo "已安装 3proxy"
    fi
  fi

  if [ -z "${BIN_TYPE}" ]; then
    echo -e "${RED}未能安装任何 socks5 实现。请手动安装 3proxy/microsocks/ss5，或检查网络。${RESET}"
    return 1
  fi

  save_meta
  start_by_type "${BIN_TYPE}" || { echo "启动失败"; return 1; }
  return 0
}

modify_flow() {
  ensure_workdir
  load_meta
  if [ -z "${BIN_TYPE}" ]; then
    EXIST="$(detect_existing_impl || true)"
    BIN_TYPE="${EXIST:-}"
  fi
  if [ -z "${BIN_TYPE}" ]; then
    echo -e "${YELLOW}未检测到现有安装。请先运行 安装。${RESET}"
    return 1
  fi

  echo "修改 socks5 配置（当前实现：${BIN_TYPE}）"
  prompt "新的监听端口（回车保留当前: ${PORT:-unset})" "${PORT:-${DEFAULT_PORT}}" NEW_PORT
  if ! [[ "${NEW_PORT}" =~ ^[0-9]+$ ]] || [ "${NEW_PORT}" -lt 1 ] || [ "${NEW_PORT}" -gt 65535 ]; then
    echo "端口无效，保留原值"
    NEW_PORT="${PORT}"
  fi
  prompt "新的用户名（回车保留当前: ${USERNAME:-unset})" "${USERNAME:-${DEFAULT_USER}}" NEW_USER
  prompt "新的密码（留空则自动生成）" "" NEW_PASS
  if [ -z "${NEW_PASS}" ]; then
    NEW_PASS="$(random_pass)"
    echo "已生成新密码：${NEW_PASS}"
  fi

  PORT="${NEW_PORT}"
  USERNAME="${NEW_USER}"
  PASSWORD="${NEW_PASS}"

  save_meta
  echo "正在重启代理以应用修改..."
  stop_socks
  start_by_type "${BIN_TYPE}" || { echo "重启失败，请检查日志"; return 1; }
  echo -e "${GREEN}修改并重启完成${RESET}"
  return 0
}

uninstall_flow() {
  stop_socks
  systemctl stop s5 2>/dev/null || true
  systemctl disable s5 2>/dev/null || true
  rm -f ${SERVICE_FILE}
  systemctl daemon-reload

  if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
    rm -rf "${WORKDIR}"
    echo -e "${GREEN}已删除${RESET}"
  else
    echo -e "${YELLOW}目录不存在，跳过删除。${RESET}"
  fi

  echo -e "${RED}卸载完成${RESET}"
  exit 0
}

status_flow() {

if systemctl is-active --quiet s5; then
    echo -e "${GREEN}socks5 正在运行${RESET}"
else
    echo -e "${RED}socks5 未运行${RESET}"
fi

systemctl status s5 --no-pager

read -n 1 -s -r -p "按任意键返回菜单..."
}

show_config_flow() {
  ensure_workdir
  load_meta

  if [ ! -f "${META_FILE}" ]; then
    echo -e "${YELLOW}未找到配置，请先安装 socks5${RESET}"
    return
  fi

  IP=$(get_best_ip)

  echo
  echo -e "${GREEN}==== 当前 Socks5 配置 ====${RESET}"
  echo -e "${YELLOW}服务器IP : ${IP}${RESET}"
  echo -e "${YELLOW}端口     : ${PORT}${RESET}"
  echo -e "${YELLOW}用户名   : ${USERNAME}${RESET}"
  echo -e "${YELLOW}密码     : ${PASSWORD}${RESET}"
  echo -e "${YELLOW}实现程序 : ${BIN_TYPE}${RESET}"
  echo

  SOCKS_URL="socks://${USERNAME}:${PASSWORD}@${IP}:${PORT}"
  TG_LINK="https://t.me/socks?server=${IP}&port=${PORT}&user=${USERNAME}&pass=${PASSWORD}"

  echo -e "${GREEN}连接信息:${RESET}"
  echo "Socks : ${SOCKS_URL}"
  echo "Telegram  : ${TG_LINK}"
  echo

  read -n 1 -s -r -p "按任意键返回菜单..."
}

main_menu() {
  while true; do
    clear
    echo -e "${GREEN}==== Socks5 管理菜单 ====${RESET}"
    echo -e "${GREEN}1) 安装${RESET}"
    echo -e "${GREEN}2) 卸载${RESET}"
    echo -e "${GREEN}3) 修改配置${RESET}"
    echo -e "${GREEN}4) 查看状态${RESET}"
    echo -e "${GREEN}5) 查看连接信息${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -r -p "$(echo -e "${GREEN}请选择 : ${RESET}")" opt < /dev/tty || opt="5"
    case "${opt}" in
      1) install_flow ;;
      2) uninstall_flow ;;
      3) modify_flow ;;
      4) status_flow ;;
      5) show_config_flow ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选项。${RESET}" ;;
    esac
  done
}

ensure_workdir
load_meta
main_menu
