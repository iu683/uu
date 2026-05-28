#!/usr/bin/env bash
#
# VPS 专属 Go版 mtg (FakeTLS) 自动化管理面板
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

# 默认安全伪装域名
DEFAULT_DOMAIN="azure.microsoft.com"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 基础工具函数与网络探测
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
    warn "当前系统不支持 systemd，忽略守护进程操作。"
    return 0
  fi
  command systemctl "$@"
}

ensure_workdir() {
  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
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
# 3. 依赖安装与 VPS 防火墙全自动放行
# =========================================================
install_dependencies() {
  info "正在安装 VPS 编译与网络必备依赖组件 (curl, wget, psmisc)..."
  if has_command apt-get; then
    apt-get update -y && apt-get install -y curl wget psmisc
  elif has_command dnf; then
    dnf install -y curl wget psmisc
  elif has_command yum; then
    yum install -y curl wget psmisc
  fi

  if [ ! -f "${BIN_PATH}" ]; then
    info "正在拉取适用于 Linux x86_64 的 mtg 核心二进制..."
    # 动态匹配架构，防止在非 x86 VPS 上报错
    local arch="amd64"
    local cmd
    cmd=$(uname -m)
    if [ "$cmd" == "x86_64" ] || [ "$cmd" == "amd64" ]; then arch="amd64";
    elif [ "$cmd" == "aarch64" ]; then arch="arm64";
    fi
    wget -q -O "${BIN_PATH}" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    chmod +x "${BIN_PATH}"
    info "mtg 主程序部署成功！位置: ${BIN_PATH}"
  fi
}

open_vps_port() {
  # 全自动检测并放行 VPS 系统内部防火墙端口，防止不通
  info "正在配置 VPS 防火墙，自动放行 TCP 端口: ${MTP_PORT}..."
  
  if has_command ufw && ufw status | grep -q "Status: active"; then
    ufw allow "${MTP_PORT}"/tcp >/dev/null 2>&1 || true
  fi

  if has_command firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="${MTP_PORT}"/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  # 兜底清空 iptables 规则限制，确保通透率
  if has_command iptables; then
    iptables -I INPUT -p tcp --dport "${MTP_PORT}" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

# =========================================================
# 4. 核心配置文件与守护进程服务生成
# =========================================================
create_service() {
  # VPS 标准 Systemd 进程级完美守护，抛弃 nohup
  cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=mtg Go-Version Telegram MTProto Proxy (FakeTLS)
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKDIR}
ExecStart=${BIN_PATH} run -b 0.0.0.0:${MTP_PORT} --cloak-port=${MTP_PORT} ${SECRET}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable mtg >/dev/null 2>&1 || true
}

save_meta() {
  cat << EOF > "${META_FILE}"
MTP_PORT='${MTP_PORT}'
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
    MTP_PORT=""
    SECRET=""
    DOMAIN=""
  fi
}

# =========================================================
# 5. 主流程控制模块（安装、修改、卸载）
# =========================================================
kill_residual_processes() {
  systemctl stop mtg >/dev/null 2>&1 || true
  pkill -9 -f "mtg run" >/dev/null 2>&1 || true
  killall mtg >/dev/null 2>&1 || true
}

write_and_start_service() {
  ensure_workdir
  kill_residual_processes
  open_vps_port
  save_meta
  create_service

  systemctl restart mtg >/dev/null 2>&1 || true
  sleep 1.5
  if systemctl is-active --quiet mtg 2>/dev/null; then
    info "mtg (FakeTLS) 守护服务已在 VPS 上平滑启动！"
  else
    error "mtg 服务未能启动，可能是端口被占用，请选择选项 7 查看系统错误日志。"
  fi
  showconf
}

inst_mtg() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户来部署 VPS 代理服务。" && exit 1
  install_dependencies

  local rand_port rand_domain
  rand_port=443 # VPS 环境强烈推荐标准的 443 端口
  rand_domain="${DEFAULT_DOMAIN}"

  echo "---------------------------------------------"
  read -rp "👉 请输入代理监听端口 (默认推荐 443): " input_port
  MTP_PORT=${input_port:-$rand_port}
  if ! [[ "${MTP_PORT}" =~ ^[0-9]+$ ]] || [ "${MTP_PORT}" -lt 1 ] || [ "${MTP_PORT}" -gt 65535 ]; then
    warn "端口输入无效，已重置为默认推荐端口: ${rand_port}"
    MTP_PORT="${rand_port}"
  fi

  read -rp "👉 请设置 FakeTLS 伪装域名 (默认: ${rand_domain}): " input_domain
  DOMAIN=${input_domain:-$rand_domain}

  info "正在为您生成基于 [${DOMAIN}] 的防封锁 FakeTLS 专属密钥..."
  SECRET=$(${BIN_PATH} generate-secret -c "${DOMAIN}" tls)

  write_and_start_service
}

changeconf() {
  load_meta
  if [ ! -f "${BIN_PATH}" ]; then
    error "未找到现有安装。请先执行选项 1 部署。"
    return 1
  fi

  clear
  echo -e "${GREEN}====== 修改 mtg 核心配置 ======${RESET}"
  echo "提示：直接敲回车将保持原参数不变"
  echo "---------------------------------------------"

  local input_port input_domain
  
  read -rp "👉 请输入新的监听端口 [当前: ${MTP_PORT:-443}]: " input_port
  if [ -n "$input_port" ]; then
    if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
      MTP_PORT="${input_port}"
    else
      warn "输入端口格式无效，回滚原配置。"
    fi
  fi

  read -rp "👉 请设置新的伪装域名 [当前: ${DOMAIN:-azure.microsoft.com}]: " input_domain
  if [ -n "$input_domain" ]; then
    DOMAIN="${input_domain}"
    info "域名已变更，正在为您重新构建专属 FakeTLS 密钥对..."
    SECRET=$(${BIN_PATH} generate-secret -c "${DOMAIN}" tls)
  fi

  write_and_start_service
}

uninstall_mtg() {
  warn "即将从当前 VPS 中彻底抹除并清理 mtg 代理组件..."
  kill_residual_processes

  systemctl disable mtg >/dev/null 2>&1 || true
  if [ -f "${SERVICE_FILE}" ]; then rm -f "${SERVICE_FILE}"; fi
  systemctl daemon-reload

  rm -f "${BIN_PATH}"
  rm -rf "${WORKDIR}"
  info "VPS 上的 mtg 全套依赖已彻底卸载干净！"
}

showconf() {
  load_meta
  if [ -z "${MTP_PORT}" ]; then
    error "未找到持久化配置元文件，请确认代理已成功安装。"
    return 1
  fi

  local ip tg_link tg_quick_link
  ip="$(get_best_ip)"

  tg_link="tg://proxy?server=${ip}&port=${MTP_PORT}&secret=${SECRET}"
  tg_quick_link="https://t.me/proxy?server=${ip}&port=${MTP_PORT}&secret=${SECRET}"

  echo -e "${GREEN}====== mtg (FakeTLS) 节点分享链接 ======${RESET}"
  echo -e "${YELLOW}● VPS公网IP :${RESET} ${ip}"
  echo -e "${YELLOW}● 监听端口  :${RESET} ${MTP_PORT}"
  echo -e "${YELLOW}● 伪装域名  :${RESET} ${DOMAIN}"
  echo -e "${YELLOW}● 伪装密钥  :${RESET} ${SECRET}"
  echo "---------------------------------------------"
  echo -e "${GREEN}Telegram 专属一键直连订阅链接 (复制到TG直接点击):${RESET}"
  echo -e "${CYAN}${tg_link}${RESET}"
  echo
  echo -e "${GREEN}外部浏览器跳转链接:${RESET}"
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
    
    local status_display="${RED}● 未运行${RESET}"
    if systemctl is-active --quiet mtg 2>/dev/null; then
      status_display="${GREEN}● 运行中 (Systemd 级托管)${RESET}"
    elif pkill -0 -f "mtg run" >/dev/null 2>&1; then
      status_display="${GREEN}● 运行中 (Pid 独立挂载)${RESET}"
    fi

    local port_display="${MTP_PORT:- -}"
    local domain_display="${DOMAIN:- -}"

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      VPS mtg FakeTLS 管理面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前状态:${RESET} ${status_display}"
    echo -e "${GREEN}开放端口:${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}当前伪装:${RESET} ${CYAN}${domain_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 全自动安装配置 mtg (VPS版)${RESET}"
    echo -e "${GREEN}2. 修改核心配置参数${RESET}"
    echo -e "${GREEN}3. 彻底从 VPS 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动代理进程${RESET}"
    echo -e "${GREEN}5. 停止代理进程${RESET}"
    echo -e "${GREEN}6. 重启/重载代理服务${RESET}"
    echo -e "${GREEN}7. 实时查看系统连接日志 (追踪)${RESET}"
    echo -e "${GREEN}8. 查看当前连接配置链接${RESET}"
    echo -e "${0}. 退出面板${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_mtg; pause ;;
      2) changeconf; pause ;;
      3) uninstall_mtg; pause ;;
      4)
        systemctl start mtg && info "服务已成功拉起！"
        pause ;;
      5)
        kill_residual_processes
        info "所有 mtg 代理服务已强制挂断终止！"
        pause ;;
      6)
        write_and_start_service
        pause ;;
      7)
        echo -e "${YELLOW}提示: 出现日志流后，按下 Ctrl + C 即可优雅退出日志。${RESET}"
        sleep 1
        journalctl -u mtg.service -n 50 -f
        ;;
      8) showconf; pause ;;
      0) exit 0 ;;
      *) error "未识别的无效指令。"; sleep 1 ;;
    esac
  done
}

menu "$@"
