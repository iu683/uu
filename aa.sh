#!/usr/bin/env bash
#
# NaiveProxy 一键管理面板 (支持远程 HTML 伪装本地化)
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CADDY_BINARY="/usr/local/bin/caddy"
readonly NAIVE_DIR="/root/naive"
readonly WEB_WWW_DIR="/var/www/html"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/caddy"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/caddy"
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
# 2. 底层工具函数
# =========================================================
has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "naiveinst.XXXXXXXXXX"
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

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
    *) error "NaiveProxy (Caddy) 暂不支持或未编译当前架构: $(uname -a)"; exit 8 ;;
  esac

  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command jq || install_software jq
  has_command tar || install_software tar
}

get_installed_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    local version_out
    version_out=$("$EXECUTABLE_INSTALL_PATH" version 2>/dev/null | head -n 1 || echo "")
    if [[ -n "$version_out" ]]; then
      echo "$version_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "未知格式"
    else
      echo "未知版本"
    fi
  else
    echo "未安装"
  fi
}

download_caddy_naive() {
  local _destination="$1"
  local _latest_tag
  _latest_tag=$(curl -sS -H 'Accept: application/vnd.github.v3+json' "https://api.github.com/repos/klzgrad/naiveproxy/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "")
  
  if [[ -z "$_latest_tag" ]]; then
    error "无法获取 NaiveProxy 最新版本号"
    return 1
  fi

  local _download_url="https://github.com/klzgrad/naiveproxy/releases/download/${_latest_tag}/naiveproxy-${_latest_tag}-linux-x64.tar.xz"
  if [[ "$ARCHITECTURE" == "arm64" ]]; then
    _download_url="https://github.com/klzgrad/naiveproxy/releases/download/${_latest_tag}/naiveproxy-${_latest_tag}-linux-arm64.tar.xz"
  fi
  
  info "正在下载集成 Naive 插件的 Caddy 核心组件: $_download_url ..."
  if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
    error "核心下载失败！请检查您的网络连接。"
    return 11
  fi
  return 0
}

tpl_caddy_server_service() {
  cat << EOF
[Unit]
Description=Caddy Server with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=$EXECUTABLE_INSTALL_PATH run --environ --config ${CADDY_CONFIG}
ExecReload=$EXECUTABLE_INSTALL_PATH reload --config ${CADDY_CONFIG} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 3. 网络与配置扩展辅助函数
# =========================================================
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

check_port() {
  local port="$1"
  if ss -tunlp 2>/dev/null | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
    return 1
  fi
  return 0
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_caddy_status() {
  if has_command systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
    echo -e "${GREEN}● 运行中${RESET}"
  else
    if pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1; then
      echo -e "${GREEN}● 运行中 (Pidmode)${RESET}"
    else
      echo -e "${RED}● 未运行${RESET}"
    fi
  fi
}

get_current_port_display() {
  if [[ -f "$CADDY_CONFIG" ]]; then
    local main_port
    main_port=$(grep -oE ':[0-9]+' "$CADDY_CONFIG" | head -n 1 | tr -d ':' || echo "")
    echo "${main_port:-443}"
  else echo "-"; fi
}

# =========================================================
# 4. 交互输入与配置写入
# =========================================================
inst_port() {
  local default_port="443"
  [[ -f "$CADDY_CONFIG" ]] && default_port=$(grep -oE ':[0-9]+' "$CADDY_CONFIG" | head -n 1 | tr -d ':' || echo "443")

  local prompt_msg="设置 NaiveProxy 监听端口 [默认: 443, 回车确认]: "
  while true; do
    read -rp "$prompt_msg" port
    port=${port:-$default_port}
    if is_valid_port "$port"; then
      if [[ "$port" != "$default_port" ]] && ! check_port "$port"; then
        error "端口 ${port} 已被其它程序占用，请更换。" && continue
      fi
      break
    else error "请输入有效的端口数字 (1-65535)"; fi
  done
}

download_custom_html() {
  local html_url="https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/toy/nahtml.html"
  mkdir -p "$WEB_WWW_DIR"
  info "正在拉取指定的伪装网页源码..."
  if curl -sS "$html_url" -o "$WEB_WWW_DIR/index.html"; then
    info "伪装网页已成功下载并缓存至本地目录: $WEB_WWW_DIR/index.html"
  else
    warn "远程伪装网页下载失败，自动生成一个基础伪装页面占位。"
    echo "<h1>Welcome to nginx!</h1>" > "$WEB_WWW_DIR/index.html"
  fi
}

write_and_show_config() {
  local hostname=$(hostname -s | sed 's/ /_/g')
  local ip=$(get_public_ip)

  # 先拉取指定的 HTML 源码到本地
  download_custom_html

  # 1. 写入服务端 Caddyfile 配置
  cat << EOF > "$CADDY_CONFIG"
:$port {
    # 开启 TLS 并自动申请证书
    tls $sb_email {
        protocols tls1.3
    }
    
    # 转发代理（Naive 核心逻辑）
    forward_proxy {
        basic_auth $auth_user $auth_pwd
        hide_ip
        hide_via
        probe_resistance
    }
    
    # 伪装站设置（直接渲染刚刚下载的本地 HTML 网页，抗沙箱嗅探能力极强）
    root * $WEB_WWW_DIR
    file_server
}
EOF

  # 修正域名绑定格式
  if [[ "$port" == "443" ]]; then
      sed -i "s|:$port|$sb_domain|g" "$CADDY_CONFIG"
  else
      sed -i "s|:$port|$sb_domain:$port|g" "$CADDY_CONFIG"
  fi

  mkdir -p "$NAIVE_DIR"
  
  # 2. 写入通用客户端 config.json 备份
  cat << EOF > "$NAIVE_DIR/config.json"
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://$auth_user:$auth_pwd@$sb_domain:$port"
}
EOF

  # 3. 固化持久化节点数据
  cat << EOF > "$NAIVE_DIR/url.txt"
====== NaiveProxy 节点信息 ======
域名    : ${sb_domain}
端口    : $port
用户名  : $auth_user
密码    : $auth_pwd
---------------------------
[信息] 客户端通用标准分享格式 (如 v2rayN / SagerNet)：
naive://$auth_user:$auth_pwd@$sb_domain:$port?padding=true#$hostname-Naive
---------------------------------
EOF

  # 4. 守护进程分支运行
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true
    
    if systemctl is-active --quiet caddy 2>/dev/null; then
      info "NaiveProxy (Caddy) 服务配置并启动成功！"
    else
      error "Caddy 服务启动失败，请运行 'systemctl status caddy' 查看日志。"
    fi
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --environ --config $CADDY_CONFIG >/dev/null 2>&1 &
    info "非 systemd 环境，程序已挂载至后台 Pid 进程池中运行。"
  fi
  
  showconf
}

# =========================================================
# 5. 主流程功能控制模块
# =========================================================
instsingbox() {
  check_environment
  
  mkdir -p /etc/caddy

  local _tmparchive=$(mktemp)
  if ! download_caddy_naive "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在解压并安装二进制可执行文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xf "$_tmparchive" -C "$_tmpdir"
  
  if install -Dm755 "$_tmpdir"/naiveproxy-*/caddy "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "安装失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  if has_command systemctl; then
    install_content -Dm644 "$(tpl_caddy_server_service)" "$SYSTEMD_SERVICES_DIR/caddy.service" "1"
  fi

  echo "---------------------------------------------"
  echo -e "配置 NaiveProxy 所需的公网可解析域名："
  read -rp "请输入你的域名 (例如: naive.example.com): " sb_domain
  [[ -z $sb_domain ]] && error "必须绑定域名才能自动化申请 TLS 证书！" && return 1

  read -rp "请输入用于申请证书的邮箱 (回车随机生成): " sb_email
  sb_email=${sb_email:-"$(date +%s%N | md5sum | cut -c 1-8)@gmail.com"}

  inst_port
  
  read -rp "设置 Naive 验证用户名 (回车默认: admin): " auth_user
  auth_user=${auth_user:-"admin"}

  read -rp "设置 Naive 验证密码 (直接回车将自动分配强随机密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

update_singbox() {
  if [[ ! -f "$CADDY_BINARY" ]]; then
    error "当前系统未安装 NaiveProxy 内核，无法执行更新。"
    return 1
  fi

  warn "即将开始平滑更新 (你的配置与运行数据不会改变)..."
  
  local _tmparchive=$(mktemp)
  if ! download_caddy_naive "$_tmparchive"; then
    rm -f "$_tmparchive" && return 1
  fi

  echo -ne "正在覆盖二进制核心文件 ... "
  local _tmpdir=$(mktemp -d)
  tar -xf "$_tmparchive" -C "$_tmpdir"
  if install -Dm755 "$_tmpdir"/naiveproxy-*/caddy "$EXECUTABLE_INSTALL_PATH"; then
    echo "成功"
  else
    rm -rf "$_tmparchive" "$_tmpdir" && error "覆盖核心失败" && return 1
  fi
  rm -rf "$_tmparchive" "$_tmpdir"

  info "正在重启服务以应用更新..."
  if has_command systemctl; then
    systemctl daemon-reload
    systemctl restart caddy >/dev/null 2>&1 || true
    info "NaiveProxy 内核已成功平滑更新！"
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --environ --config "$CADDY_CONFIG" >/dev/null 2>&1 &
    info "内核已更新并于后台重启运行。"
  fi
}

unstsingbox() {
  warn "即将从当前系统中彻底卸载 NaiveProxy (Caddy)"

  if has_command systemctl; then
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true
    remove_file "$SYSTEMD_SERVICES_DIR/caddy.service"
    systemctl daemon-reload
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
  fi
  
  remove_file "$EXECUTABLE_INSTALL_PATH"
  rm -rf /etc/caddy "$NAIVE_DIR" "$WEB_WWW_DIR"

  info "NaiveProxy 已彻底从您的系统中移除！"
}

changeconf() {
  if [[ ! -f "$CADDY_CONFIG" ]]; then
    error "配置文件不存在，请先安装 NaiveProxy"
    return 1
  fi

  clear
  echo -e "${GREEN}====== 修改 NaiveProxy 配置 ======${RESET}"
  echo "提示：重新配置需要填入完整参数"
  echo "---------------------------------------------"
  
  read -rp "请输入你的解析域名: " sb_domain
  [[ -z $sb_domain ]] && error "域名不能为空！" && return 1

  read -rp "请输入申请证书的邮箱: " sb_email
  sb_email=${sb_email:-"admin@gmail.com"}

  inst_port 

  read -rp "设置 Naive 验证用户名: " auth_user
  auth_user=${auth_user:-"admin"}

  read -rp "设置 Naive 验证密码: " auth_pwd
  [[ -z $auth_pwd ]] && auth_pwd=$(generate_random_password)

  write_and_show_config
  info "配置修改并应用成功！"
}

showconf() {
  if [[ ! -f "$CADDY_CONFIG" ]]; then
    error "未找到 Caddyfile 配置文件，请确保已成功部署节点。"
    return
  fi

  if [[ -f "$NAIVE_DIR/url.txt" ]]; then
     cat "$NAIVE_DIR/url.txt"
  else
     error "持久化配置缓存不存在。"
  fi
}

# =========================================================
# 6. 面板主菜单循环
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && error "请切换至 root 用户运行此面板脚本。" && exit 1
  check_environment

  while true; do
    clear
    local status=$(get_caddy_status)
    local version=$(get_installed_version)
    local port_show=$(get_current_port_display)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      NaiveProxy 面板           ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 NaiveProxy${RESET}"
    echo -e "${GREEN}2. 更新 NaiveProxy${RESET}"
    echo -e "${GREEN}3. 卸载 NaiveProxy${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 NaiveProxy${RESET}"
    echo -e "${GREEN}6. 停止 NaiveProxy${RESET}"
    echo -e "${GREEN}7. 重启 NaiveProxy${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"

    local choice=""
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1) instsingbox; pause ;;
      2) update_singbox; pause ;;
      3) unstsingbox; pause ;;
      4) changeconf; pause ;;
      5) 
        if has_command systemctl; then
          systemctl start caddy && info "服务已成功启动！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --environ --config "$CADDY_CONFIG" >/dev/null 2>&1 &
          info "进程已在后台启动！"
        fi
        pause ;;
      6) 
        if has_command systemctl; then
          systemctl stop caddy && info "服务已成功停止！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" && info "后台进程已终止！"
        fi
        pause ;;
      7) 
        if has_command systemctl; then
          systemctl restart caddy && info "服务已成功重启！"
        else
          pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
          "$EXECUTABLE_INSTALL_PATH" run --environ --config "$CADDY_CONFIG" >/dev/null 2>&1 &
          info "后台进程已重启！"
        fi
        pause ;;
      8) 
        if has_command systemctl; then
          journalctl -u caddy.service -n 50 --no-pager
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
