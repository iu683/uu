#!/usr/bin/env bash
#
# Sing-box (NaiveProxy) 管理面板 
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly SB_CONFIG="/etc/sing-box/config.json"
readonly SB_BINARY="/usr/local/bin/sing-box"
readonly SB_DIR="/root/sb_node"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/sing-box"
REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 官方原生底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "sbservinst.XXXXXXXXXX"
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

install_content() {
  local _install_flags="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"
  local _tmpfile="$(mktemp)"

  echo -ne "安装 $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "已存在"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "完成"
  fi
  rm -f "$_tmpfile"
}

remove_file() {
  local _target="$1"
  echo -ne "移除 $_target ... "
  if rm -f "$_target"; then
    echo -e "完成"
  fi
}

detect_package_manager() {
  [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]] && return 0
  has_command apt && PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install' && return 0
  has_command dnf && PACKAGE_MANAGEMENT_INSTALL='dnf -y install' && return 0
  has_command yum && PACKAGE_MANAGEMENT_INSTALL='yum -y install' && return 0
  has_command apk && PACKAGE_MANAGEMENT_INSTALL='apk add --no-cache' && return 0
  return 1
}

install_software() {
  local _package_name="$1"
  if ! detect_package_manager; then
    error "未检测到支持的包管理器，请手动安装 $_package_name"
    exit 65
  fi
  echo "正在安装缺失的依赖 '$_package_name' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    error "无法通过包管理器安装 '$_package_name'，请手动安装。"
    exit 65
  fi
}

check_environment() {
  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "本脚本仅支持 Linux 系统。"
    exit 95
  fi

  case "$(uname -m)" in
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command tar || install_software tar
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1 || echo "未知格式"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    return
  fi
  local _tag_name=$(jq -r '[.[] | select(.prerelease==false and .draft==false)][0].tag_name' "$_tmpfile" 2>/dev/null || echo "")
  rm -f "$_tmpfile"
  
  if [[ -n "$_tag_name" ]]; then
    echo "${_tag_name##*\/}"
  else
    echo "v1.12.3"
  fi
}

download_singbox() {
  local _version="$1"
  local _destination="$2"
  local _ver_num="${_version#v}"
  
  local _download_url="$REPO_URL/releases/download/$_version/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE.tar.gz"
  
  info "正在下载官方 Sing-box 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_singbox_server_service_base() {
  cat << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$EXECUTABLE_INSTALL_PATH run -c $SB_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 面板辅助网络与配置扩展函数
# =========================================================
get_sb_status() {
  if has_command systemctl && systemctl is-active --quiet sing-box 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_domain_display() {
  if [[ -f "$SB_CONFIG" ]]; then
    local domain
    domain=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG" 2>/dev/null || echo "")
    echo "${domain:- -}"
  else echo "-"; fi
}

# 随机字符串生成函数
generate_random_string() {
  local length=$1
  # 使用 tr 过滤出纯字母与数字，防止特殊符号断开 JSON
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length" || true
}

# =========================================================
# 4. 面板核心交互与配置文件处理
# =========================================================
write_and_show_config() {
  mkdir -p "$CONFIG_DIR"

  cat << EOF > "$SB_CONFIG"
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "username": "${sb_username}",
          "password": "${sb_password}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sb_domain}",
        "acme": {
          "domain": ["${sb_domain}"],
          "email": "${sb_email}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  mkdir -p "$SB_DIR"
  
  local encoded_node_name=$(curl -s -o /dev/null -w %{url_effective} --url-query "x=${sb_node_name}" "" | sed 's/^.*x=//')
  local share_link="naive://${sb_username}:${sb_password}@${sb_domain}:443#${sb_node_name}"

  cat << EOF > "$SB_DIR/url.txt"
Flowz / Shadowrocket 订阅分享链接:
${share_link}
EOF

  cat << EOF > "$SB_DIR/meta.env"
sb_domain="${sb_domain}"
sb_email="${sb_email}"
sb_username="${sb_username}"
sb_password="${sb_password}"
sb_node_name="${sb_node_name}"
EOF

  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true
    
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      info "Sing-box 服务配置并启动成功！"
    else
      error "Sing-box 服务启动失败，请运行 'journalctl -u sing-box -f' 查看错误日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "非 systemd 环境，程序已挂载至后台 Pid 进程池中运行。"
  fi
  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================
inst_singbox() {
  check_environment
  
  info "🧹 正在释放 80 和 443 端口以防冲突..."
  systemctl stop caddy nginx apache2 sing-box 2>/dev/null || true

  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  
  local _tmpfile_tar=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
    rm -f "$_tmpfile_tar" && return 1
  fi

  echo -ne "正在解压并安装二进制可执行文件 ... "
  local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
  tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
  
  local _ver_num="${latest_version#v}"
  if install -Dm755 "$_tmpdir_extract/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE/sing-box" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "安装失败" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  if has_command systemctl; then
    install_content -Dm644 "$(tpl_singbox_server_service_base)" "$SYSTEMD_SERVICES_DIR/sing-box.service" "1"
  fi

  # 生成随机默认参数
  local rand_user=$(generate_random_string 8)
  local rand_pass=$(generate_random_string 16)
  local rand_email="$(generate_random_string 10)@gmail.com"

  echo "---------------------------------------------"
  read -rp "👉 请输入解析好的域名 (例如: naive.example.com): " sb_domain
  [[ -z "$sb_domain" ]] && error "域名不能为空！" && return 1

  read -rp "👉 请输入你的邮箱 (默认随机: ${rand_email}): " sb_email
  sb_email=${sb_email:-"$rand_email"}

  read -rp "👉 请设置 NaiveProxy 用户名 (默认随机: ${rand_user}): " sb_username
  sb_username=${sb_username:-"$rand_user"}

  read -rp "👉 请设置 NaiveProxy 密码 (默认随机: ${rand_pass}): " sb_password
  sb_password=${sb_password:-"$rand_pass"}

  read -rp "👉 请给这个节点起个名字 (默认: NaiveProxy): " sb_node_name
  sb_node_name=${sb_node_name:-"NaiveProxy"}

  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$SB_BINARY" ]]; then
    error "当前系统未安装 Sing-box，无法执行更新。"
    return 1
  fi

  info "正在检查新版本..."
  local current_version=$(get_installed_version)
  local latest_version=$(get_latest_version)

  info "当前安装版本: ${YELLOW}${current_version}${RESET}"
  info "官方最新版本: ${GREEN}${latest_version}${RESET}"

  if [[ "$current_version" == *"$latest_version"* || "$latest_version" == *"$current_version"* ]]; then
    info "您当前已经是最新版本，无需更新。"
    return 0
  fi

  warn "检测到新版本，即将开始平滑更新 (你的节点配置不会改变)..."
  
  local _tmpfile_tar=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
    rm -f "$_tmpfile_tar" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
  tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
  
  local _ver_num="${latest_version#v}"
  if install -Dm755 "$_tmpdir_extract/sing-box-$_ver_num-$OPERATING_SYSTEM-$ARCHITECTURE/sing-box" "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  info "正在重启 Sing-box 服务以应用更新..."
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl restart sing-box >/dev/null 2>&1 || true
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      info "Sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但服务重启失败，请运行 'journalctl -u sing-box -f' 检查错误。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "Sing-box 核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  warn "即将从当前系统中彻底卸载 Sing-box (NaiveProxy)"

  if has_command systemctl; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    remove_file "$SYSTEMD_SERVICES_DIR/sing-box.service"
    systemctl daemon-reload
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi

  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -rf /etc/sing-box "$SB_DIR"

  info "Sing-box 已彻底从您的系统中移除！"
}

changeconf() {
  if [[ ! -f "$SB_CONFIG" ]]; then
    error "配置文件不存在，请先安装 Sing-box"
    return 1
  fi

  if [[ -f "$SB_DIR/meta.env" ]]; then
    source "$SB_DIR/meta.env"
  else
    sb_domain=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONFIG")
    sb_email=$(jq -r '.inbounds[0].tls.acme.email' "$SB_CONFIG")
    sb_username=$(jq -r '.inbounds[0].users[0].username' "$SB_CONFIG")
    sb_password=$(jq -r '.inbounds[0].users[0].password' "$SB_CONFIG")
    sb_node_name="NaiveProxy"
  fi

  clear
  echo -e "${GREEN}====== 修改 Sing-box Naive 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  local input_domain input_email input_user input_pass input_name

  read -rp "👉 请输入解析好的域名 [当前: ${sb_domain}]: " input_domain
  sb_domain=${input_domain:-$sb_domain}

  read -rp "👉 请输入你的邮箱 [当前: ${sb_email}]: " input_email
  sb_email=${input_email:-$sb_email}

  read -rp "👉 请设置 NaiveProxy 用户名 [当前: ${sb_username}]: " input_user
  sb_username=${input_user:-$sb_username}

  read -rp "👉 请设置 NaiveProxy 密码 [当前: ${sb_password}]: " input_pass
  sb_password=${input_pass:-$sb_password}

  read -rp "👉 请给这个节点起个名字 [当前: ${sb_node_name}]: " input_name
  sb_node_name=${input_name:-$sb_node_name}

  write_and_show_config
  info "配置修改并应用成功！"
}

showconf() {
  if [[ ! -d "$SB_DIR" || ! -f "$SB_DIR/url.txt" ]]; then
    error "未找到分享链接配置文件。"
    return
  fi
  echo -e "${GREEN}====== 节点分享链接 ======${RESET}"
  cat "$SB_DIR/url.txt"
  echo
}

# =========================================================
# 6. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_sb_status)
    local version=$(get_installed_version)
    local domain_show=$(get_current_domain_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Sing-box NaiveProxy 面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}域名   :${RESET} ${YELLOW}${domain_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}2. 更新 Sing-box 核心${RESET}"
    echo -e "${GREEN}3. 卸载 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}4. 修改节点配置${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) inst_box=inst_singbox; $inst_box; pause ;;
      2) update_singbox; pause ;;
      3) uninstall_singbox; pause ;;
      4) changeconf; pause ;;
      5) 
        if has_command systemctl; then
          systemctl start sing-box && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop sing-box && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart sing-box && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u sing-box.service -n 50 --no-pager
        else
          warn "当前环境不支持 systemd 集中日志管理。"
        fi
        pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
