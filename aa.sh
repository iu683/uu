#!/usr/bin/env bash

set -e

PKG="@anthropic-ai/claude-code"

color() {
  local code="$1"
  shift
  printf "\033[%sm%s\033[0m\n" "$code" "$*"
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

green() {
  color "32" "$*"
}

pause() {
  read -rp "按回车继续..." _
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
  ok "卸载完成"
}

auth_claude() {
  if ! check_claude; then
    warn "请先安装 Claude Code"
    return 1
  fi

  info "启动登录授权..."
  claude auth
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
  info "环境检查"
  echo "USER : ${USER:-unknown}"
  echo "SHELL: ${SHELL:-unknown}"
  echo "PATH : $PATH"
  echo

  if command -v npm >/dev/null 2>&1; then
    echo "npm root -g: $(npm root -g 2>/dev/null || echo '获取失败')"
  fi

  if command -v npm >/dev/null 2>&1; then
    if npm bin -g >/dev/null 2>&1; then
      echo "npm bin -g : $(npm bin -g 2>/dev/null)"
    else
      warn "当前 npm 可能不支持 'npm bin -g'"
    fi
  fi

  if command -v claude >/dev/null 2>&1; then
    echo "claude path: $(command -v claude)"
    echo "version    : $(claude --version 2>/dev/null || echo '读取失败')"
  else
    echo "claude path: 未安装"
  fi
}

fix_path_hint() {
  warn "如果安装后仍提示 'claude: command not found'，通常是 PATH 问题。"
  echo
  echo "可以先执行："
  echo "  npm root -g"
  echo
  echo "再查看全局可执行目录，例如常见位置："
  echo "  ~/.npm-global/bin"
  echo "  ~/.nvm/versions/node/<version>/bin"
  echo "  /usr/local/bin"
  echo
  echo "把对应目录加入 PATH，例如："
  echo '  export PATH="$HOME/.npm-global/bin:$PATH"'
  echo
  echo "然后执行："
  echo "  source ~/.bashrc"
  echo "或"
  echo "  source ~/.zshrc"
}

menu() {
  clear
  green "=================================="
  green "   Claude Code 一键菜单管理"
  green "=================================="
  green "1. 安装 Claude Code"
  green "2. 检查版本"
  green "3. 登录授权"
  green "4. 快速测试"
  green "5. 进入交互模式"
  green "6. 更新 Claude Code"
  green "7. 卸载 Claude Code"
  green "8. 查看环境信息"
  green "9. PATH 修复提示"
  green "0. 退出"
  green "=================================="
}

main() {
  while true; do
    menu
    read -rp "请输入选项: " choice
    case "$choice" in
      1)
        install_claude
        pause
        ;;
      2)
        check_claude || true
        pause
        ;;
      3)
        auth_claude || true
        pause
        ;;
      4)
        test_claude || true
        pause
        ;;
      5)
        interactive_claude || true
        pause
        ;;
      6)
        update_claude
        pause
        ;;
      7)
        uninstall_claude
        pause
        ;;
      8)
        show_env
        pause
        ;;
      9)
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
