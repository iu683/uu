#!/usr/bin/env bash
#
# Telegram MTProto Proxy 高级管理面板
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
WORKDIR="${HOME:-/root}/mtprotoproxy"
readonly META_FILE="${WORKDIR}/meta.env"
readonly CONFIG_FILE="${WORKDIR}/config_local.py"
readonly SERVICE_FILE="/etc/systemd/system/mtproto.service"
readonly REPO_URL="https://github.com/alexbers/mtprotoproxy.git"

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

random_user() {
  echo "tg_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
}

random_secret() {
  openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32
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
# 3. 依赖自动安装环境
# =========================================================
install_dependencies() {
  info "正在检查并安装编译与运行所需的系统依赖..."
  if has_command apt-get; then
    apt-get update -y
    apt-get install -y git python3 python3-pip curl build-essential libssl-dev zlib1g-dev
  elif has_command dnf; then
    dnf install -y git python3 python3-pip curl openssl-devel zlib-devel
  elif has_command yum; then
    yum install -y git python3 python3-pip curl openssl-devel zlib-devel
  else
    warn "未找到主流包管理器，请确保 git, python3, openssl 依赖已手动装妥。"
  fi
}

# =========================================================
# 4. 核心配置文件与守护进程服务生成
# =========================================================
generate_mtproto_config() {
  # 构建合法的 Python 字典配置格式
  cat << EOF > "${CONFIG_FILE}"
# -*- coding: utf-8 -*-
PORT = ${PORT}

USERS = {
    "${USERNAME}": "${SECRET}"
}

# 默认关闭高级混淆，确保通用兼容性
TLS_DOMAIN = ""
EOF
  chmod 600 "${CONFIG_FILE}"
}

create_service() {
  cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=MTProto Proxy Service
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKDIR}
ExecStart=/usr/bin/python3 ${WORKDIR}/mtprotoproxy.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable mtproto >/dev/null 2>&1 || true
  fi
}

save_meta() {
  cat << EOF > "${META_FILE}"
PORT='${PORT}'
USERNAME='${USERNAME}'
SECRET='${SECRET}'
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
    SECRET=""
  fi
}

# =========================================================
# 5. 主流程控制模块（安装、修改、卸载、连接查看）
# =========================================================
write_and_start_service() {
  save_meta
  generate_mtproto_config
  create_service

  if has_command systemctl; then
    systemctl restart mtproto >/dev/null 2>&1 || true
    sleep 1.5
    if systemctl is-active --quiet mtproto 2>/dev/null; then
      info "MTProto 服务配置并启动成功！"
    else
      error "MTProto 服务启动失败，请运行 'journalctl -u mtproto -f' 查看错误日志。"
    fi
  else
    pkill -f "mtprotoproxy.py" || true
    python3 "${WORKDIR}/mtprotoproxy.py" >/dev/null 2>&1 &
    info "非 systemd 环境，进程已挂载至后台独立运行。"
  fi
  showconf
}

inst_mtproto() {
  if [ -d "${WORKDIR}" ] && [ -f "${WORKDIR}/mtprotoproxy.py" ]; then
    warn "检测到当前目录已存在 MTProto 项目，将跳过源码克隆，直接进入配置重置。"
  else
    install_dependencies
    info "正在拉取 MTProto 官方源码库..."
    mkdir -p "$(dirname "${WORKDIR}")"
    git clone "${REPO_URL}" "${WORKDIR}"
  fi

  cd "${WORKDIR}" || exit 1

  # 如果存在默认 config.py 则留档备份
  if [ -f "config.py" ] && [ ! -f "config.py.bak" ]; then
    cp config.py config.py.bak
  fi

  local rand_user rand_secret rand_port
  rand_user="$(random_user)"
  rand_secret="$(random_secret)"
  rand_port=443 # 推荐使用 443

  echo "---------------------------------------------"
  read -rp "👉 请输入监听端口 (默认推荐: ${rand_port}): " input_port
  PORT=${input_port:-$rand_port}
  if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
    warn "端口输入无效，已自动回退为默认端口: ${rand_port}"
    PORT="${rand_port}"
  fi

  read -rp "👉 请设置用户名 (默认随机: ${rand_user}): " input_user
  USERNAME=${input_user:-$rand_user}

  read -rp "👉 请设置32位16进制密钥 (默认随机: ${rand_secret}): " input_secret
  SECRET=${input_secret:-$rand_secret}

  write_and_start_service
}

changeconf() {
  load_meta
  if [ ! -d "${WORKDIR}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    error "未找到现有安装。请先执行选项 1 进行全新部署。"
    return 1
  fi

  clear
  echo -e "${GREEN}====== 修改 MTProto 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"

  local input_port input_user input_secret
  
  read -rp "👉 请输入新的监听端口 [当前: ${PORT:-443}]: " input_port
  if [ -n "$input_port" ]; then
    if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
      PORT="${input_port}"
    else
      warn "输入端口格式不合法，保留原端口。"
    fi
  fi

  read -rp "👉 请设置新的用户名 [当前: ${USERNAME:-unset}]: " input_user
  USERNAME=${input_user:-$USERNAME}

  read -rp "👉 请设置新的32位密钥 [当前: ${SECRET:-unset}]: " input_secret
  SECRET=${input_secret:-$SECRET}

  write_and_start_service
}

uninstall_mtproto() {
  warn "即将从当前系统中彻底卸载并清理 MTProto 代理服务..."

  if has_command systemctl; then
    systemctl stop mtproto >/dev/null 2>&1 || true
    systemctl disable mtproto >/dev/null 2>&1 || true
    if [ -f "${SERVICE_FILE}" ]; then
      rm -f "${SERVICE_FILE}"
    fi
    systemctl daemon-reload
  else
    pkill -f "mtprotoproxy.py" || true
  fi

  rm -rf "${WORKDIR}"
  info "MTProto 代理面板及源码环境已彻底从系统中移除！"
}

showconf() {
  load_meta
  if [ -z "${PORT}" ]; then
    error "未找到元配置文件，请确认代理已成功安装。"
    return 1
  fi

  local ip tg_link tg_quick_link
  ip="$(get_best_ip)"

  # 拼装标准 Telegram 内置快链
  tg_link="tg://proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
  tg_quick_link="https://t.me/proxy?server=${ip}&port=${PORT}&secret=${SECRET}"

  echo -e "${GREEN}====== MTProto 节点分享链接 ======${RESET}"
  echo -e "${YELLOW}● 服务器IP :${RESET} ${ip}"
  echo -e "${YELLOW}● 端口     :${RESET} ${PORT}"
  echo -e "${YELLOW}● 用户名   :${RESET} ${USERNAME}"
  echo -e "${YELLOW}● 密钥     :${RESET} ${SECRET}"
  echo "---------------------------------------------"
  echo -e "${GREEN}Telegram 专属配置快链 (复制到TG内直接点击):${RESET}"
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
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1

  while true; do
    clear
    load_meta
    
    local status_display
    if has_command systemctl && systemctl is-active --quiet mtproto 2>/dev/null; then
      status_display="${GREEN}● 运行中${RESET}"
    else
      if pkill -0 -f "mtprotoproxy.py" >/dev/null 2>&1; then
        status_display="${GREEN}● 运行中 (Pidmode)${RESET}"
      else
        status_display="${RED}● 未运行${RESET}"
      fi
    fi

    local port_display="${PORT:- -}"
    local user_display="${USERNAME:- -}"

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        MTProto Proxy 管理面板      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} ${status_display}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}用户   :${RESET} ${CYAN}${user_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 MTProto Proxy${RESET}"
    echo -e "${GREEN}2. 修改配置${RESET}"
    echo -e "${GREEN}3. 卸载 MTProto Proxy${RESET}"
    echo -e "${GREEN}4. 启动 MTProto Proxy${RESET}"
    echo -e "${GREEN}5. 停止 MTProto Proxy${RESET}"
    echo -e "${GREEN}6. 重启 MTProto Proxy${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看连接配置${RESET}"
    echo -e "${GREEN}0. 退出面板${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_mtproto; pause ;;
      2) changeconf; pause ;;
      3) uninstall_mtproto; pause ;;
      4)
        if has_command systemctl; then
          systemctl start mtproto && info "服务已成功启动！"
        else
          pkill -f "mtprotoproxy.py" || true
          python3 "${WORKDIR}/mtprotoproxy.py" >/dev/null 2>&1 &
          info "服务已在后台挂载启动！"
        fi
        pause ;;
      5)
        if has_command systemctl; then
          systemctl stop mtproto && info "服务已成功停止！"
        else
          pkill -f "mtprotoproxy.py" && info "后台进程已终止！"
        fi
        pause ;;
      6)
        if has_command systemctl; then
          systemctl restart mtproto && info "服务已成功完成平滑重启！"
        else
          pkill -f "mtprotoproxy.py" || true
          python3 "${WORKDIR}/mtprotoproxy.py" >/dev/null 2>&1 &
          info "后台独立进程已重载刷新！"
        fi
        pause ;;
      7)
        if has_command systemctl; then
          echo -e "${YELLOW}提示: 按下 Ctrl + C 即可退出日志追踪模式。${RESET}"
          sleep 1
          journalctl -u mtproto.service -n 50 -f
        else
          warn "当前环境不支持 Systemd 日志追踪。"
          pause
        fi
        ;;
      8) showconf; pause ;;
      0) exit 0 ;;
      *) error "未识别的无效指令，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
