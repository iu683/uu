#!/usr/bin/env bash
#
# NaiveProxy 一键管理面板 (精细菜单版)
# SPDX-License-Identifier: MIT
#
# =========================================================
# 1. 核心控制与全局环境初始化
# =========================================================
set -Eop pipefail
export LANG=en_US.UTF-8

# 基础目录与硬编码配置
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly NAIVE_DIR="/root/naive"
readonly WEB_WWW_DIR="/var/www/html"
EXECUTABLE_INSTALL_PATH="/usr/bin/caddy"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/caddy"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 终端颜色代码
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# =========================================================
# 2. 底层工具与依赖检查
# =========================================================
has_command() {
  type -P "$1" > /dev/null 2>&1
}

info() { echo -e "${GREEN}[信息] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}" >&2; }
error() { echo -e "${RED}[错误] $*${RESET}" >&2; }
pause() { read -n 1 -s -r -p "按任意键返回菜单..." || true; echo; }

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '+/=' | cut -c 1-16
}

detect_package_manager() {
  has_command apt && echo 'apt -y --no-install-recommends install' && return 0
  has_command dnf && echo 'dnf -y install' && return 0
  has_command yum && echo 'yum -y install' && return 0
  has_command apk && echo 'apk add --no-cache' && return 0
  return 1
}

install_software() {
  local pkg="$1"
  local pm_cmd
  pm_cmd=$(detect_package_manager) || { error "未找到支持的包管理器"; exit 1; }
  info "正在安装依赖: $pkg ..."
  $pm_cmd "$pkg" >/dev/null 2>&1
}

check_environment() {
  [[ "x$(uname)" != "xLinux" ]] && { error "本脚本仅支持 Linux 系统"; exit 1; }
  
  has_command curl || install_software curl
  has_command grep || install_software grep
  has_command tar || install_software tar

  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
      ARCH_TAG="amd64"
  elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
      ARCH_TAG="arm64"
  else
      error "❌ 不支持的架构：$ARCH"
      exit 1
  fi
}

# =========================================================
# 3. 核心固件动态提取下载
# =========================================================
download_and_extract_caddy() {
  info "正在检索 passeway/naiveproxy 存储库的最新服务端固件..."
  
  local latest_tag
  latest_tag=$(curl -fsSL https://api.github.com/repos/passeway/naiveproxy/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+' || echo "")
  
  if [[ -z "$latest_tag" ]]; then
      error "❌ 无法获取最新版本号"
      return 1
  fi

  local assets_json download_url
  assets_json=$(curl -fsSL "https://api.github.com/repos/passeway/naiveproxy/releases/tags/${latest_tag}")
  download_url=$(echo "$assets_json" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep "$ARCH_TAG" | grep '\.tar\.gz$' | head -n 1 || echo "")

  if [[ -z "$download_url" ]]; then
      error "❌ 未找到适用于架构 $ARCH_TAG 的 tar.gz 核心包"
      return 1
  fi

  local filename
  filename=$(basename "$download_url")

  info "正在下载: $download_url"
  curl -L "$download_url" -o "$filename" || { error "❌ 下载固件失败"; return 1; }
  
  info "正在解压并安装 caddy 到 /usr/bin/ ..."
  tar -xvzf "$filename" -C /usr/bin/ || { error "❌ 解压失败"; rm -f "$filename"; return 1; }
  
  chmod +x /usr/bin/caddy
  rm -f "$filename"
  return 0
}

# =========================================================
# 4. 伪装网页与配置服务模块
# =========================================================
download_custom_html() {
  local html_url="https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/toy/nahtml.html"
  mkdir -p "$WEB_WWW_DIR"
  info "正在拉取指定的远程伪装网页源码 (nahtml)..."
  if curl -fsSL "$html_url" -o "$WEB_WWW_DIR/index.html"; then
    info "伪装网页已成功下载并缓存至本地目录: $WEB_WWW_DIR/index.html"
  else
    warn "远程伪装网页下载失败，自动生成一个基础伪装页面。"
    echo "<h1>Welcome to nginx!</h1>" > "$WEB_WWW_DIR/index.html"
  fi
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

write_and_show_config() {
  local hostname=$(hostname -s | sed 's/ /_/g')
  
  download_custom_html

  mkdir -p "$CONFIG_DIR"
  cat << EOF > "$CADDY_CONFIG"
:$port {
    tls $sb_email {
        protocols tls1.3
    }
    
    forward_proxy {
        basic_auth $auth_user $auth_pwd
        hide_ip
        hide_via
        probe_resistance
    }
    
    root * $WEB_WWW_DIR
    file_server
}
EOF

  if [[ "$port" == "443" ]]; then
      sed -i "s|:$port|$sb_domain|g" "$CADDY_CONFIG"
  else
      sed -i "s|:$port|$sb_domain:$port|g" "$CADDY_CONFIG"
  fi

  mkdir -p "$NAIVE_DIR"
  
  cat << EOF > "$NAIVE_DIR/config.json"
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://$auth_user:$auth_pwd@$sb_domain:$port"
}
EOF

  cat << EOF > "$NAIVE_DIR/url.txt"
====== NaiveProxy 节点信息 ======
域名    : ${sb_domain}
端口    : $port
用户名  : $auth_user
密码    : $auth_pwd
---------------------------
[信息] 客户端通用标准分享链接 (如 v2rayN / SagerNet)：
naive://$auth_user:$auth_pwd@$sb_domain:$port?padding=true#$hostname-Naive
---------------------------------
EOF

  if type -P systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true
  else
    pkill -f "$EXECUTABLE_INSTALL_PATH run" || true
    "$EXECUTABLE_INSTALL_PATH" run --environ --config $CADDY_CONFIG >/dev/null 2>&1 &
  fi
  
  showconf
}

# =========================================================
# 5. 业务流程控制
# =========================================================
inst_naive() {
  check_environment
  download_and_extract_caddy || return 1

  if type -P systemctl >/dev/null 2>&1; then
    echo "$(tpl_caddy_server_service)" > "$SYSTEMD_SERVICES_DIR/caddy.service"
  fi

  echo "---------------------------------------------"
  read -rp "请输入你的解析域名 (例如: naive.example.com): " sb_domain
  [[ -z $sb_domain ]] && { error "域名不能为空"; return 1; }

  read -rp "请输入用于申请证书的邮箱 (回车随机生成): " sb_email
  sb_email=${sb_email:-"$(date +%s%N | md5sum | cut -c 1-8)@gmail.com"}

  read -rp "设置监听端口 [默认: 443, 回车确认]: " port
  port=${port:-443}
  
  read -rp "设置 Naive 验证用户名 (默认: admin): " auth_user
  auth_user=${auth_user:-"admin"}

  read -rp "设置 Naive 验证密码 (回车随机生成强密码): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

changeconf() {
  if [[ ! -f "$CADDY_CONFIG" ]]; then
    error "配置文件不存在，请先安装 NaiveProxy"
    return 1
  fi
  echo "---------------------------------------------"
  read -rp "请输入新的解析域名: " sb_domain
  [[ -z $sb_domain ]] && { error "域名不能为空"; return 1; }

  read -rp "请输入申请证书的邮箱: " sb_email
  sb_email=${sb_email:-"admin@gmail.com"}

  read -rp "设置新的监听端口 [默认: 443]: " port
  port=${port:-443}

  read -rp "设置新的用户名 [默认: admin]: " auth_user
  auth_user=${auth_user:-"admin"}

  read -rp "设置新的密码 (留空随机生成): " auth_pwd
  auth_pwd=${auth_pwd:-$(generate_random_password)}

  write_and_show_config
}

showconf() {
  if [[ -f "$NAIVE_DIR/url.txt" ]]; then
     cat "$NAIVE_DIR/url.txt"
  else
     error "未找到部署的节点配置"
  fi
}

get_caddy_status() {
  if type -P systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy 2>/dev/null; then
    echo -e "${GREEN}运行中${RESET}"
  else
    pgrep -f "$EXECUTABLE_INSTALL_PATH run" >/dev/null 2>&1 && echo -e "${GREEN}运行中 (Pidmode)${RESET}" || echo -e "${RED}未运行${RESET}"
  fi
}

get_caddy_version() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" ]]; then
    "$EXECUTABLE_INSTALL_PATH" version 2>/dev/null | head -n 1 | awk '{print $1}' || echo "未知版本"
  else
    echo "未安装"
  fi
}

get_current_port_display() {
  if [[ -f "$CADDY_CONFIG" ]]; then
    local main_port
    main_port=$(grep -oE ':[0-9]+' "$CADDY_CONFIG" | head -n 1 | tr -d ':' || echo "")
    echo "${main_port:-443}"
  else
    echo "-"
  fi
}

# =========================================================
# 6. 面板主菜单
# =========================================================
menu() {
  [[ $EUID -ne 0 ]] && { error "请切换至 root 用户运行此脚本"; exit 1; }
  check_environment

  while true; do
    clear
    local status version port_show
    status=$(get_caddy_status)
    version=$(get_caddy_version)
    port_show=$(get_current_port_display)

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

    local choice
    read -r -p "请输入选项: " choice || true
    case "$choice" in
      1) inst_naive; pause ;;
      2) check_environment; download_and_extract_caddy; if type -P systemctl >/dev/null 2>&1; then systemctl restart caddy; fi; info "内核已升级完毕！"; pause ;;
      3) if type -P systemctl >/dev/null 2>&1; then systemctl stop caddy; systemctl disable caddy; rm -f "$SYSTEMD_SERVICES_DIR/caddy.service"; fi; rm -f "$EXECUTABLE_INSTALL_PATH"; rm -rf /etc/caddy "$NAIVE_DIR" "$WEB_WWW_DIR"; info "清理完毕，已完全卸载"; pause ;;
      4) changeconf; pause ;;
      5) if type -P systemctl >/dev/null 2>&1; then systemctl start caddy; else pkill -f "$EXECUTABLE_INSTALL_PATH run" || true; "$EXECUTABLE_INSTALL_PATH" run --environ --config $CADDY_CONFIG >/dev/null 2>&1 & fi; info "服务已启动"; pause ;;
      6) if type -P systemctl >/dev/null 2>&1; then systemctl stop caddy; else pkill -f "$EXECUTABLE_INSTALL_PATH run" || true; fi; info "服务已停止"; pause ;;
      7) if type -P systemctl >/dev/null 2>&1; then systemctl restart caddy; else pkill -f "$EXECUTABLE_INSTALL_PATH run" || true; "$EXECUTABLE_INSTALL_PATH" run --environ --config $CADDY_CONFIG >/dev/null 2>&1 & fi; info "服务已重启"; pause ;;
      8) if type -P systemctl >/dev/null 2>&1; then journalctl -u caddy.service -n 50 --no-pager; else error "当前运行在非 systemd 模式，无法通过系统命令检索日志"; fi; pause ;;
      9) showconf; pause ;;
      0) exit 0 ;;
      *) error "输入错误，请重新选择"; sleep 1 ;;
    esac
  done
}

menu "$@"
