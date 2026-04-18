#!/usr/bin/env bash

set -e

PKG="@anthropic-ai/claude-code"

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

check_claude() {
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code 已安装: $(claude --version 2>/dev/null || echo '已安装但版本读取失败')"
    return 0
  fi

  warn "未检测到 claude 命令"
  return 1
}

install_claude() {
  check_node || return 1
  info "开始安装 Claude Code..."
  npm install -g "$PKG"
  ok "安装完成"
  check_claude || true
}

update_claude() {
  check_node || return 1
  info "开始更新 Claude Code..."
  npm install -g "$PKG@latest"
  ok "更新完成"
  check_claude || true
}

uninstall_claude() {
  check_node || return 1
  info "开始卸载 Claude Code..."

  npm uninstall -g "$PKG" || true

  # 强制删除所有相关内容
  run_root rm -rf "$HOME/.claude" 2>/dev/null || true
  run_root rm -f /usr/local/bin/claude /usr/bin/claude 2>/dev/null || true

  hash -r 2>/dev/null || true

  ok "卸载完成"
}

auth_status() {
  if ! check_claude; then
    warn "请先安装 Claude Code"
    return 1
  fi

  info "检查登录状态..."
  claude auth status
}


auth_claude() {
  if ! check_claude; then
    warn "请先安装 Claude Code"
    return 1
  fi

  info "启动登录授权..."
  claude auth login
}

test_claude() {
  if ! check_claude; then
    warn "请先安装 Claude Code"
    return 1
  fi

  info "执行快速测试..."
  claude -p "用一句话说明当前目录适合做什么"
}

interactive_claude() {
  if ! check_claude; then
    warn "请先安装 Claude Code"
    return 1
  fi

  info "进入 Claude 交互模式..."
  claude -c
}

show_env() {
  detect_os
  info "环境检查"
  echo "OS_ID    : ${OS_ID:-unknown}"
  echo "OS_LIKE  : ${OS_LIKE:-unknown}"
  echo "USER     : ${USER:-unknown}"
  echo "SHELL    : ${SHELL:-unknown}"
  echo "PATH     : $PATH"
  echo

  if command -v node >/dev/null 2>&1; then
    echo "node     : $(node -v)"
  else
    echo "node     : 未安装"
  fi

  if command -v npm >/dev/null 2>&1; then
    echo "npm      : $(npm -v)"
    echo "npm root : $(npm root -g 2>/dev/null || echo '获取失败')"
  else
    echo "npm      : 未安装"
  fi

  if command -v claude >/dev/null 2>&1; then
    echo "claude   : $(command -v claude)"
    echo "version  : $(claude --version 2>/dev/null || echo '读取失败')"
  else
    echo "claude   : 未安装"
  fi
}

fix_path_hint() {
  warn "如果安装后仍提示 'claude: command not found'，通常是 PATH 问题。"
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
  install_claude
}

menu() {
  clear
  green "=================================="
  green "   Claude Code 菜单管理"
  green "=================================="
  green " 1. 安装Node.js + Claude Code"
  green " 2. 查看登录状态"
  green " 3. 安装Claude Code"
  green " 4. 检查版本"
  green " 5. 登录授权"
  green " 6. 快速测试"
  green " 7. 进入交互模式"
  green " 8. 更新 Claude Code"
  green " 9. 卸载 Claude Code"
  green "10. 查看环境信息"
  green "11. PATH 修复提示"
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
        auth_status || true
        pause
        ;;
      3)
        install_claude
        pause
        ;;
      4)
        check_claude || true
        pause
        ;;
      5)
        auth_claude || true
        pause
        ;;
      6)
        test_claude || true
        pause
        ;;
      7)
        interactive_claude || true
        pause
        ;;
      8)
        update_claude
        pause
        ;;
      9)
        uninstall_claude
        pause
        ;;
      10)
        show_env
        pause
        ;;
      11)
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
