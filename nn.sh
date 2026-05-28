#!/usr/bin/env bash
#
# Telegram mtg (Go版 FakeTLS) 高级管理面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
WORKDIR="${HOME:-/root}/mtg_proxy"
readonly META_FILE="${WORKDIR}/meta.env"
readonly SERVICE_FILE="/etc/systemd/system/mtg.service"
readonly BIN_PATH="/usr/local/bin/mtg"
readonly DOWNLOAD_URL="https://raw.githubusercontent.com/whunt1/onekeymakemtg/master/builds/mtg-linux-amd64"

# 默认伪装域名
DEFAULT_DOMAIN="www.cloudflare.com"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 基础工具函数与环境探测
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

random_port() {
  shuf -i 20000-60000 -n 1
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

# =========================================================
# 3. 依赖包自动安装与组件同步
# =========================================================
install_dependencies() {
  info "正在安装必要的系统依赖组件 (psmisc, curl, wget)..."
  if has_command apt-get; then
    apt-get update -y && apt-get install -y psmisc curl wget
  elif has_command yum; then
    yum install -y psmisc curl wget
  else
    warn "未能通过主流包管理器同步依赖，请确保系统已安装 wget 和 psmisc。"
  fi

  if [ ! -f "${BIN_PATH}" ]; then
    info "正在从源码仓库同步编译好的 mtg-linux-amd64 核心二进制..."
    wget -O "${BIN_PATH}" --no-check-certificate "${DOWNLOAD_URL}"
    chmod +x "${BIN_PATH}"
    info "mtg 核心主程序部署成功！位置: ${BIN_PATH}"
  fi
}

# =========================================================
# 4. 守护进程服务生成与元数据持久化
# =========================================================
create_service() {
  # 统一采用标准的 systemd 替代容易丢进程的 nohup 挂载方式
  cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=mtg Go-Version Telegram MTProto Proxy
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKDIR}
ExecStart=${BIN_PATH} run -b 0.0.0.0:${PORT} --cloak-port=${PORT} ${SECRET}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable mtg >/dev/null 2>&1 || true
  fi
}

save_meta() {
  cat << EOF > "${META_FILE}"
PORT='${PORT}'
SECRET='${SECRET}'
DOMAIN='${DOMAIN}'
EOF
  chmod 600 "${META_FILE}"
}

load_meta() {
  if [ -f "${META_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
  else
    PORT=""
    SECRET=""
    DOMAIN=""
  fi
}

# =========================================================
# 5. 主流程控制模块（安装、修改、卸载、状态管理）
# =========================================================
kill_residual_processes() {
  if has_command systemctl; then
    systemctl stop mtg >/dev/null 2>&1 || true
  fi
  killall mtg >/dev/null 2>&1 || true
}

write_and_start_service() {
  ensure_workdir
  kill_residual_processes
  save_meta
  create_service

  if has_command systemctl; then
    systemctl restart mtg >/dev/null 2>&1 || true
    sleep 1.5
    if systemctl is-active --quiet mtg 2>/dev/null; then
      info "mtg (FakeTLS) 服务核心参数应用成功，服务已成功拉起！"
    else
      error "mtg 服务未能启动，可能是端口被占用，请前往选项 7 查看系统日志。"
    fi
  else
    nohup ${BIN_PATH} run -b 0.0.0.0:${PORT} --cloak-port=${PORT} ${SECRET} >> "${WORKDIR}/mtg.log" 2>&1 &
    info "非 systemd 环境，已通过 nohup 挂载至后台运行。"
  fi
  showconf
}

ensure_workdir() {
  mkdir -p "${WORKDIR}"
  chmod 700 "${WORKDIR}"
}

inst_mtg() {
  install_dependencies
  ensure_workdir

  local rand_port rand_domain
  rand_port=443 # 强烈推荐 443
  rand_domain="${DEFAULT_DOMAIN}"

  echo "---------------------------------------------"
  read -rp "👉 请输入代理监听端口 (默认推荐: ${rand_port}): " input_port
  PORT=${input_port:-$rand_port}
  if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
    warn "端口输入无效，已自动回归默认端口: ${rand_port}"
    PORT="${rand_port}"
  fi

  read -rp "👉 请设置 FakeTLS 伪装域名 (默认: ${rand_domain}): " input_domain
  DOMAIN=${input_domain:-$rand_domain}

  info "正在通过 mtg 生成基于 [${DOMAIN}] 的防封锁 FakeTLS 高级密钥..."
  SECRET=$(${BIN_PATH} generate-secret -c "${DOMAIN}" tls)

  write_and_start_service
}

changeconf() {
  load_meta
  if [ ! -f "${BIN_PATH}" ]; then
    error "系统未找到 mtg 主程序，请先执行选项 1 进行全新部署。"
    return 1
  fi

  clear
  echo -e "${GREEN}====== 修改 mtg (FakeTLS) 核心配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"

  local input_port input_domain
  
  read -rp "👉 请输入新的监听端口 [当前: ${PORT:-443}]: " input_port
  if [ -n "$input_port" ]; then
    if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
      PORT="${input_port}"
    else
      warn "输入端口格式不合法，保留原端口。"
    fi
  fi

  read -rp "👉 请设置新的伪装域名 [当前: ${DOMAIN:-itunes.apple.com}]: " input_domain
  if [ -n "$input_domain" ]; then
    DOMAIN="${input_domain}"
    info "域名已变更，正在为您重新构建专用 FakeTLS 密钥对..."
    SECRET=$(${BIN_PATH} generate-secret -c "${DOMAIN}" tls)
  fi

  write_and_start_service
}

uninstall_mtg() {
  warn "即将从当前系统中彻底卸载并清理 mtg (Go版) 代理服务..."
  kill_residual_processes

  if has_command systemctl; then
    systemctl disable mtg >/dev/null 2>&1 || true
    if [ -f "${SERVICE_FILE}" ]; then rm -f "${SERVICE_FILE}"; fi
    systemctl daemon-reload
  fi

  rm -f "${BIN_PATH}"
  rm -rf "${WORKDIR}"
  info "卸载流执行完毕，全套核心二进制与元数据已被无痕抹除！"
}

showconf() {
  load_meta
  if [ -z "${PORT}" ]; then
    error "未找到持久化配置元文件，请确认代理已成功安装。"
    return 1
  fi

  local ip tg_link tg_quick_link
  ip="$(get_best_ip)"

  # mtg 生成的密钥对已经自带防封的 FakeTLS 前缀，可直接无缝拼装直连链接
  tg_link="tg://proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
  tg_quick_link="https://t.me/proxy?server=${ip}&port=${PORT}&secret=${SECRET}"

  echo -e "${GREEN}====== mtg (FakeTLS) 节点分享链接 ======${RESET}"
  echo -e "${YELLOW}● 服务器IP :${RESET} ${ip}"
  echo -e "${YELLOW}● 监听端口 :${RESET} ${PORT}"
  echo -e "${YELLOW}● 伪装域名 :${RESET} ${DOMAIN}"
  echo -e "${YELLOW}● 伪装密钥 :${RESET} ${SECRET}"
  echo "---------------------------------------------"
  echo -e "${GREEN}Telegram 专属防封锁直连快链 (发给TG好友直接点):${RESET}"
  echo -e "${CYAN}${tg_link}${RESET}"
  echo
  echo -e "${GREEN}外部浏览器跳转快链:${RESET}"
  echo -e "${CYAN}${tg_quick_link}${RESET}"
  echo
}

# =========================================================
# 6. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至超级管理员 root 用户运行此面板脚本。" && exit 1

  while true; do
    clear
    load_meta
    
    local status_display
    if has_command systemctl && systemctl is-active --quiet mtg 2>/dev/null; then
      status_display="${GREEN}● 运行中 (Systemd)${RESET}"
    else
      if pkill -0 -f "mtg run" >/dev/null 2>&1; then
        status_display="${GREEN}● 运行中 (Pidmode)${RESET}"
      else
        status_display="${RED}● 未运行${RESET}"
      fi
    fi

    local port_display="${PORT:- -}"
    local domain_display="${DOMAIN:- -}"

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        mtg (FakeTLS) 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status_display}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}伪装   :${RESET} ${CYAN}${domain_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 mtg (FakeTLS)${RESET}"
    echo -e "${GREEN}2. 修改配置参数${RESET}"
    echo -e "${GREEN}3. 彻底卸载服务${RESET}"
    echo -e "${GREEN}4. 启动代理服务${RESET}"
    echo -e "${GREEN}5. 停止代理服务${RESET}"
    echo -e "${GREEN}6. 重启代理服务${RESET}"
    echo -e "${GREEN}7. 实时查看连接日志 (追踪查看)${RESET}"
    echo -e "${GREEN}8. 查看当前连接配置链接${RESET}"
    echo -e "${GREEN}0. 退出面板${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_mtg; pause ;;
      2) changeconf; pause ;;
      3) uninstall_mtg; pause ;;
      4)
        if has_command systemctl; then
          systemctl start mtg && info "服务已唤醒启动！"
        else
          nohup ${BIN_PATH} run -b 0.0.0.0:${PORT} --cloak-port=${PORT} ${SECRET} >> "${WORKDIR}/mtg.log" 2>&1 &
          info "进程已重新挂载至后台！"
        fi
        pause ;;
      5)
        kill_residual_processes
        info "所有 mtg 代理进程均已强制挂断终止！"
        pause ;;
      6)
        write_and_start_service
        pause ;;
      7)
        if has_command systemctl; then
          echo -e "${YELLOW}提示: 出现日志流后，按下 Ctrl + C 即可退出日志追踪状态。${RESET}"
          sleep 1
          journalctl -u mtg.service -n 50 -f
        else
          if [ -f "${WORKDIR}/mtg.log" ]; then
            tail -n 50 -f "${WORKDIR}/mtg.log"
          else
            warn "未找到系统托管日志文件。"
            pause
          fi
        fi
        ;;
      8) showconf; pause ;;
      0) exit 0 ;;
      *) error "输入了无效的行内指令，请重新进行确认。"; sleep 1 ;;
    esac
  done
}

menu "$@"
