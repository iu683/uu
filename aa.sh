#!/usr/bin/env bash

set -e

PKG="@google/gemini-cli"

color() {
  local code="$1"
  shift
  printf "\033[%sm%s\033[0m\n" "$code" "$*"
}

green() {
  color "32" "$*"
}

info() {
  color "36" "[INFO] $*"
}

ok() {
  color "32" "[OK] $*"
}

warn() {
  color "33" "[WARN] $*"
}

err() {
  color "31" "[ERROR] $*"
}

pause() {
  read -rp "按回车继续..." _
}

require_sudo() {
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    err "当前不是 root，且系统未安装 sudo"
    return 1
  fi
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="$(uname -s)"
    OS_LIKE=""
  fi
}

get_shell_rc() {
  if [ -n "${ZSH_VERSION:-}" ] || [ "${SHELL:-}" = "/bin/zsh" ]; then
    echo "$HOME/.zshrc"
  else
    echo "$HOME/.bashrc"
  fi
}

install_node_debian() {
  require_sudo || return 1
  info "检测到 Debian/Ubuntu 系统，开始安装 Node.js 20.x"
  run_root apt update
  run_root apt install -y curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_20.x | run_root bash -
  run_root apt install -y nodejs
}

install_node_rhel() {
  require_sudo || return 1
  info "检测到 RHEL/CentOS/Rocky/AlmaLinux 系统，开始安装 Node.js 20.x"
  if command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y curl
    curl -fsSL https://rpm.nodesource.com/setup_20.x | run_root bash -
    run_root dnf install -y nodejs
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y curl
    curl -fsSL https://rpm.nodesource.com/setup_20.x | run_root bash -
    run_root yum install -y nodejs
  else
    err "未找到 dnf 或 yum"
    return 1
  fi
}

install_node_alpine() {
  require_sudo || return 1
  info "检测到 Alpine 系统，开始安装 Node.js"
  run_root apk add nodejs npm
}

install_node_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    err "未检测到 Homebrew，请先安装 brew"
    return 1
  fi
  info "检测到 macOS，使用 Homebrew 安装 Node.js"
  brew install node
}

install_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "Node.js 已安装"
    info "Node: $(node -v)"
    info "npm : $(npm -v)"
    return 0
  fi

  detect_os

  case "$OS_ID" in
    ubuntu|debian)
      install_node_debian
      ;;
    centos|rhel|rocky|almalinux|ol|fedora)
      install_node_rhel
      ;;
    alpine)
      install_node_alpine
      ;;
    macos|darwin)
      install_node_macos
      ;;
    *)
      case "$OS_LIKE" in
        *debian*)
          install_node_debian
          ;;
        *rhel*|*fedora*)
          install_node_rhel
          ;;
        *)
          if [ "$(uname -s)" = "Darwin" ]; then
            install_node_macos
          else
            err "暂不支持自动安装 Node.js，系统类型: ${OS_ID:-unknown}"
            return 1
          fi
          ;;
      esac
      ;;
  esac

  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "Node.js 安装完成"
    info "Node: $(node -v)"
    info "npm : $(npm -v)"
  else
    err "Node.js 安装后仍未检测到 node/npm"
    return 1
  fi
}

check_node() {
  if ! command -v node >/dev/null 2>&1; then
    err "未检测到 node，请先安装 Node.js"
    return 1
  fi

  if ! command -v npm >/dev/null 2>&1; then
    err "未检测到 npm，请先安装 npm"
    return 1
  fi

  info "Node: $(node -v)"
  info "npm : $(npm -v)"
}

check_gemini() {
  if command -v gemini >/dev/null 2>&1; then
    ok "Gemini CLI 已安装: $(gemini --version 2>/dev/null || echo '已安装但版本读取失败')"
    return 0
  fi

  warn "未检测到 gemini 命令"
  return 1
}

check_gemini_key() {
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    ok "已检测到 GEMINI_API_KEY"
    return 0
  fi

  warn "当前未设置 GEMINI_API_KEY"
  return 1
}

ensure_gemini_ready() {
  check_gemini || return 1
  check_gemini_key || return 1
}

install_gemini() {
  check_node || return 1
  info "开始安装 Gemini CLI..."
  npm install -g "$PKG"
  ok "安装完成"
  check_gemini || true
}

update_gemini() {
  check_node || return 1
  info "开始更新 Gemini CLI..."
  npm install -g "$PKG@latest"
  ok "更新完成"
  check_gemini || true
}

uninstall_gemini() {
  check_node || return 1
  info "开始卸载 Gemini CLI..."
  npm uninstall -g "$PKG" || true
  ok "卸载完成"
}

setup_gemini_key() {
  local key rc_file
  rc_file="$(get_shell_rc)"

  echo
  echo "AI Studio API Key 入口:"
  echo "https://aistudio.google.com/api-keys"
  echo

  read -rp "请输入 GEMINI_API_KEY: " key

  if [ -z "$key" ]; then
    warn "未输入 API Key，已取消"
    return 1
  fi

  export GEMINI_API_KEY="$key"

  if [ -f "$rc_file" ] && grep -F 'export GEMINI_API_KEY=' "$rc_file" >/dev/null 2>&1; then
    warn "检测到 $rc_file 中已有 GEMINI_API_KEY，请手动检查是否需要更新"
  else
    printf '\nexport GEMINI_API_KEY="%s"\n' "$key" >> "$rc_file"
    ok "已写入 $rc_file"
  fi

  ok "当前会话已加载 GEMINI_API_KEY"
  info "如需立即在新终端生效，请执行: source $rc_file"
}

show_api_key_help() {
  echo "AI Studio API Key 入口:"
  echo "https://aistudio.google.com/api-keys"
  echo
  echo "设置方法:"
  echo 'export GEMINI_API_KEY="你的API_KEY"'
}

test_gemini() {
  ensure_gemini_ready || return 1

  info "执行 Gemini 快速测试..."
  gemini -p "用一句话说明当前目录适合做什么"
}

interactive_gemini() {
  ensure_gemini_ready || return 1

  info "进入 Gemini 交互模式..."
  gemini
}

show_env() {
  detect_os
  info "环境检查"
  echo "OS_ID          : ${OS_ID:-unknown}"
  echo "OS_LIKE        : ${OS_LIKE:-unknown}"
  echo "USER           : ${USER:-unknown}"
  echo "SHELL          : ${SHELL:-unknown}"
  echo "PATH           : $PATH"
  echo

  if command -v node >/dev/null 2>&1; then
    echo "node           : $(node -v)"
  else
    echo "node           : 未安装"
  fi

  if command -v npm >/dev/null 2>&1; then
    echo "npm            : $(npm -v)"
    echo "npm root -g    : $(npm root -g 2>/dev/null || echo '获取失败')"
  else
    echo "npm            : 未安装"
  fi

  if command -v gemini >/dev/null 2>&1; then
    echo "gemini         : $(command -v gemini)"
    echo "gemini version : $(gemini --version 2>/dev/null || echo '读取失败')"
  else
    echo "gemini         : 未安装"
  fi

  if [ -n "${GEMINI_API_KEY:-}" ]; then
    echo "GEMINI_API_KEY : 已设置"
  else
    echo "GEMINI_API_KEY : 未设置"
  fi
}

fix_path_hint() {
  warn "如果安装后仍提示 'gemini: command not found'，通常是 PATH 问题。"
  echo
  echo "先查看 npm 全局目录："
  echo "  npm root -g"
  echo
  echo "常见可执行目录："
  echo "  ~/.npm-global/bin"
  echo "  ~/.nvm/versions/node/<version>/bin"
  echo "  /usr/local/bin"
  echo
  echo "例如加入 PATH："
  echo '  export PATH="$HOME/.npm-global/bin:$PATH"'
  echo
  echo "生效命令："
  echo "  source ~/.bashrc"
  echo "或"
  echo "  source ~/.zshrc"
}

install_all() {
  install_node
  install_gemini
}

menu() {
  clear
  green "=================================="
  green "    Gemini CLI 一键菜单管理"
  green "=================================="
  green " 1. 安装 Node.js + Gemini CLI"
  green " 2. 仅安装 Node.js"
  green " 3. 安装 Gemini CLI"
  green " 4. 检查 Gemini 版本"
  green " 5. 检查 GEMINI_API_KEY"
  green " 6. 配置 GEMINI_API_KEY"
  green " 7. API Key 获取入口"
  green " 8. Gemini 快速测试"
  green " 9. 进入 Gemini 交互模式"
  green "10. 更新 Gemini CLI"
  green "11. 卸载 Gemini CLI"
  green "12. 查看环境信息"
  green "13. PATH 修复提示"
  green " 0. 退出"
  green "=================================="
}

main() {
  while true; do
    menu
    read -rp "请输入选项: " choice
    case "$choice" in
      1)
        install_all
        pause
        ;;
      2)
        install_node
        pause
        ;;
      3)
        install_gemini
        pause
        ;;
      4)
        check_gemini || true
        pause
        ;;
      5)
        check_gemini_key || true
        pause
        ;;
      6)
        setup_gemini_key || true
        pause
        ;;
      7)
        show_api_key_help
        pause
        ;;
      8)
        test_gemini || true
        pause
        ;;
      9)
        interactive_gemini || true
        pause
        ;;
      10)
        update_gemini
        pause
        ;;
      11)
        uninstall_gemini
        pause
        ;;
      12)
        show_env
        pause
        ;;
      13)
        fix_path_hint
        pause
        ;;
      0)
        ok "已退出"
        exit 0
        ;;
      *)
        warn "无效选项"
        pause
        ;;
    esac
  done
}

main
