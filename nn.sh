#!/usr/bin/env bash
#
# Sing-box (NaiveProxy) Alpine 专属管理面板
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
readonly SB_DIR="/root/NaiveProxy"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/sing-box"
INIT_SERVICE_DIR="/etc/init.d"
CONFIG_DIR="/etc/sing-box"
REPO_URL="https://github.com/SagerNet/sing-box"
API_BASE_URL="https://api.github.com/repos/SagerNet/sing-box"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 自动检测环境变量
OPERATING_SYSTEM="linux"
ARCHITECTURE="${ARCHITECTURE:-}"

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. Alpine 原生底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp -t "sbservinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

# OpenRC 服务操作封装
rc_service() {
  if ! has_command rc-service; then
    return 1
  fi
  command rc-service "$@"
}

rc_update() {
  if ! has_command rc-update; then
    return 1
  fi
  command rc-update "$@"
}

install_content() {
  local _perms="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"

  echo -ne "安装 $_destination ... "
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "已存在"
  else
    if mkdir -p "$(dirname "$_destination")" && echo "$_content" > "$_destination" && chmod "$_perms" "$_destination"; then
      echo -e "完成"
    else
      echo -e "失败"
    fi
  fi
}

remove_file() {
  local _target="$1"
  echo -ne "移除 $_target ... "
  if rm -f "$_target"; then
    echo -e "完成"
  fi
}

install_software() {
  local _package_name="$1"
  echo "正在通过 apk 安装缺失的依赖 '$_package_name' ... "
  if apk add --no-cache "$_package_name" >/dev/null 2>&1; then
    echo "依赖安装成功"
  else
    error "无法通过 apk 安装 '$_package_name'，请手动检查 Alpine 源配置。"
    exit 65
  fi
}

check_environment() {
  if [[ ! -f /etc/alpine-release ]]; then
    warn "检测到当前系统可能不是 Alpine Linux，但脚本将继续尝试运行..."
  fi

  case "$(uname -m)" in
    'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
    'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
    *) error "不支持当前架构: $(uname -a)"; exit 8 ;;
  esac

  # 确保 Alpine 环境具备基本依赖与 glibc 兼容层
  has_command bash || install_software bash
  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command tar || install_software tar
  
  # 关键修复：Alpine 必须安装 gcompat 才能运行官方 Sing-box 二进制文件
  if ! apk info -e gcompat >/dev/null 2>&1; then
    info "检测到缺少 glibc 运行环境，正在安装 gcompat 兼容层..."
    install_software gcompat
  fi
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1 || echo "未知格式"
    else
      echo "未知版本(请尝试安装gcompat)"
    fi
  else
    echo "未安装"
  fi
}

get_latest_version() {
  local _tmpfile=$(mktemp)
  if ! curl -sS -H 'Accept: application/vnd.github.v3+json' "$API_BASE_URL/releases" -o "$_tmpfile"; then
    rm -f "$_tmpfile"
    echo "v1.12.3"
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

# Alpine OpenRC 专属服务脚本底座
tpl_singbox_server_openrc_base() {
  cat << 'EOF'
#!/sbin/openrc-run

description="Sing-box NaiveProxy Service"
supervisor="supervise-daemon"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
extra_started_commands="reload"

depend() {
    need net
    after firewall
}

reload() {
    ebegin "Reloading sing-box configuration"
    supervise-daemon --signal HUP --name sing-box
    eend $?
}
EOF
}

# =========================================================
# 3. 面板辅助网络与配置扩展函数
# =========================================================
get_sb_status() {
  if has_command rc-service && rc-service sing-box status >/dev/null 2>&1; then
    echo -e "${GREEN}● 运行中 ${RESET}"
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

# 完美适配 BusyBox 的随机字符串生成函数
generate_random_string() {
  local length=$1
  cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length" || true
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
      "listen_port": ${sb_port},
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
  
  local encoded_node_name=$(jq -rn --arg x "$sb_node_name" '$x|@uri')
  local share_link="naive+https://${sb_username}:${sb_password}@${sb_domain}:${sb_port}#${sb_node_name}"

  cat << EOF > "$SB_DIR/url.txt"
V2rayN 配置分享链接:
${share_link}
EOF

  cat << EOF > "$SB_DIR/meta.env"
sb_domain="${sb_domain}"
sb_email="${sb_email}"
sb_username="${sb_username}"
sb_password="${sb_password}"
sb_node_name="${sb_node_name}"
sb_port="${sb_port}"
EOF

  # 托管环境行为控制 (OpenRC 适配)
  if has_command rc-service && [ -d "$INIT_SERVICE_DIR" ]; then
    rc_update add sing-box default >/dev/null 2>&1 || true
    rc_service sing-box restart >/dev/null 2>&1 || true
    
    if rc_service sing-box status >/dev/null 2>&1; then
      info "Sing-box 服务通过 OpenRC 配置并启动成功！"
    else
      error "Sing-box 服务启动失败，请检查 /var/log/messages 查看错误日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "非 OpenRC 环境，程序已挂载至后台常驻进程模式。"
  fi
  showconf
}

# =========================================================
# 5. 主流程控制模块与更新功能
# =========================================================
inst_singbox() {
  check_environment
  
  info "🧹 正在释放 80 和 443 端口以防冲突..."
  if has_command rc-service; then
    rc_service caddy stop >/dev/null 2>&1 || true
    rc_service nginx stop >/dev/null 2>&1 || true
    rc_service sing-box stop >/dev/null 2>&1 || true
  else
    pkill -f "caddy" || true
    pkill -f "nginx" || true
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi

  info "获取官方最新发布版本中..."
  local latest_version=$(get_latest_version)
  
  local _tmpfile_tar=$(mktemp)
  if ! download_singbox "$latest_version" "$_tmpfile_tar"; then
    rm -f "$_tmpfile_tar" && return 1
  fi

  echo -ne "正在解压并安装二进制可执行文件 ... "
  local _tmpdir_extract=$(command mktemp -d -t sbtar.XXXXXXXXXX)
  tar -zxf "$_tmpfile_tar" -C "$_tmpdir_extract"
  
  local _extracted_binary=$(find "$_tmpdir_extract" -type f -name "sing-box" | head -n 1)

  if [[ -n "$_extracted_binary" ]]; then
    mkdir -p "$(dirname "$EXECUTABLE_INSTALL_PATH")"
    if cp "$_extracted_binary" "$EXECUTABLE_INSTALL_PATH" && chmod 755 "$EXECUTABLE_INSTALL_PATH"; then
      echo "成功"
    else
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "安装失败" && return 1
    fi
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "找不到解压核心" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  # 写入 Alpine OpenRC 服务脚本
  install_content "0755" "$(tpl_singbox_server_openrc_base)" "$INIT_SERVICE_DIR/sing-box" "1"

  local rand_user=$(generate_random_string 8)
  local rand_pass=$(generate_random_string 16)
  local rand_email="$(generate_random_string 10)@gmail.com"
  local hostname_str=$(hostname 2>/dev/null || echo "alpine")
  local default_remark="${hostname_str}-NaiveProxy"

  echo "---------------------------------------------"
  read -rp "👉 请输入解析好的域名 (例如: naive.example.com): " sb_domain
  [[ -z "$sb_domain" ]] && error "域名不能为空！" && return 1

  read -rp "👉 请输入你的邮箱 (默认随机: ${rand_email}): " sb_email
  sb_email=${sb_email:-"$rand_email"}

  read -rp "👉 请设置 NaiveProxy 用户名 (默认随机: ${rand_user}): " sb_username
  sb_username=${sb_username:-"$rand_user"}

  read -rp "👉 请设置 NaiveProxy 密码 (默认随机: ${rand_pass}): " sb_password
  sb_password=${sb_password:-"$rand_pass"}

  read -rp "👉 请设置节点备注 (默认: ${default_remark}): " sb_node_name
  sb_node_name=${sb_node_name:-$default_remark}

  read -rp "👉 请设置监听端口 (默认: 443): " sb_port
  sb_port=${sb_port:-443}

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
  
  local _extracted_binary=$(find "$_tmpdir_extract" -type f -name "sing-box" | head -n 1)
  if [[ -n "$_extracted_binary" ]]; then
    if cp "$_extracted_binary" "$EXECUTABLE_INSTALL_PATH" && chmod 755 "$EXECUTABLE_INSTALL_PATH"; then
      echo "成功"
    else
      rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "覆盖核心失败" && return 1
    fi
  else
    rm -rf "$_tmpfile_tar" "$_tmpdir_extract" && error "解压错误" && return 1
  fi
  rm -rf "$_tmpfile_tar" "$_tmpdir_extract"

  info "正在重启 Sing-box 服务以应用更新..."
  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
    rc_service sing-box restart >/dev/null 2>&1 || true
    if rc_service sing-box status >/dev/null 2>&1; then
      info "Sing-box 已成功平滑更新至 ${GREEN}${latest_version}${RESET}！"
    else
      error "核心更新成功，但 OpenRC 重启服务失败。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
    info "Sing-box 核心已更新并于后台重启运行。"
  fi
}

uninstall_singbox() {
  warn "即将从当前系统中彻底卸载 Sing-box (NaiveProxy)"

  if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
    rc_service sing-box stop >/dev/null 2>&1 || true
    rc_update del sing-box default >/dev/null 2>&1 || true
    remove_file "$INIT_SERVICE_DIR/sing-box"
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
    sb_port=$(jq -r '.inbounds[0].listen_port' "$SB_CONFIG")
    sb_node_name="NaiveProxy"
  fi

  [[ -z "$sb_port" || "$sb_port" == "null" ]] && sb_port=443

  clear
  echo -e "${GREEN}====== 修改 Sing-box Naive 配置 ======${RESET}"
  echo "提示：直接敲回车将保持原有配置不变"
  echo "---------------------------------------------"
  
  local input_domain input_email input_user input_pass input_name input_port

  read -rp "👉 请输入解析好的域名 [当前: ${sb_domain}]: " input_domain
  sb_domain=${input_domain:-$sb_domain}

  read -rp "👉 请输入你的邮箱 [当前: ${sb_email}]: " input_email
  sb_email=${input_email:-$sb_email}

  read -rp "👉 请设置 NaiveProxy 用户名 [当前: ${sb_username}]: " input_user
  sb_username=${input_user:-$sb_username}

  read -rp "👉 请设置 NaiveProxy 密码 [当前: ${sb_password}]: " input_pass
  sb_password=${input_pass:-$sb_password}

  read -rp "👉 请设置节点备注 [当前: ${sb_node_name}]: " input_name
  sb_node_name=${input_name:-$sb_node_name}

  read -rp "👉 请设置监听端口 [当前: ${sb_port}]: " input_port
  sb_port=${input_port:-$sb_port}

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
    echo -e "${GREEN}    Sing-box NaiveProxy 面板    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}域名   :${RESET} ${YELLOW}${domain_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}2. 更新 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}3. 卸载 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}4. 修改配置 ${RESET}"
    echo -e "${GREEN}5. 启动 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}6. 停止 Sing-box (Naive)${RESET}"
    echo -e "${GREEN}7. 重启 Sing-box (Naive)${RESET}"
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
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box start && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box stop && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command rc-service && [ -f "$INIT_SERVICE_DIR/sing-box" ]; then
          rc_service sing-box restart && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run -c "$SB_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if [[ -f /var/log/messages ]]; then
          echo -e "${CYAN}--- 最近 50 行相关系统日志 ---${RESET}"
          tail -n 50 /var/log/messages | grep -E 'sing-box|supervise-daemon' || tail -n 50 /var/log/messages
          echo "--------------------------------------"
          if [[ -f "$EXECUTABLE_INSTALL_PATH" && -f "$SB_CONFIG" ]]; then
            "$EXECUTABLE_INSTALL_PATH" check -c "$SB_CONFIG" || true
          fi
        else
          warn "未找到系统日志文件 /var/log/messages"
        fi
        pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "无效输入，请重新选择。"; sleep 1 ;;
    esac
  done
}

menu "$@"
