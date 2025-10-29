#!/bin/bash

APP_NAME="EDUKY-Monitor"
PYTHON_BIN=$(which python3)
PID_FILE=".pid"
GREEN="\033[1;32m"
RESET="\033[0m"

REPO_URL="https://github.com/eduky/EDUKY-Monitor.git"
APP_DIR="EDUKY-Monitor"
SERVICE_FILE="/etc/systemd/system/eduky-monitor.service"
USER_NAME=$(whoami)
WORKDIR=$(pwd)/$APP_DIR

# =======================
# 克隆仓库
# =======================
clone_repo() {
  if [ -d "$APP_DIR" ]; then
    echo " 目录 $APP_DIR 已存在，跳过克隆。"
  else
    echo "📥 正在克隆仓库..."
    git clone "$REPO_URL"
  fi
  cd "$APP_DIR" || exit
  echo "✅ 已进入目录 $(pwd)"
}

# =======================
# 检查 Python
# =======================
check_python() {
  if [ -z "$PYTHON_BIN" ]; then
    echo "❌ 未检测到 Python3，请先安装。"
    exit 1
  fi
}

# =======================
# 安装依赖
# =======================
install_app() {
  check_python
  echo "📦 安装依赖中..."
  pip install -r requirements.txt
  echo "✅ 依赖安装完成。"
}

# =======================
# 启动服务
# =======================
start_app() {
  check_python
  clone_repo
  if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
    echo " $APP_NAME 已在运行中 (PID: $(cat $PID_FILE))"
    return
  fi
  echo "🚀 启动 $APP_NAME..."
  nohup $PYTHON_BIN main.py > app.log 2>&1 &
  echo $! > "$PID_FILE"
  echo "✅ 启动成功！日志文件: app.log"
  echo "✅ 访问：http://localhost:5000"
  echo "✅ 用户名: admin 密码: admin123 "
}

# =======================
# 停止服务
# =======================
stop_app() {
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
      echo "🛑 停止 $APP_NAME (PID: $PID)"
      kill $PID
      rm -f "$PID_FILE"
      echo "✅ 已停止。"
    else
      echo " 未检测到运行中的进程。"
      rm -f "$PID_FILE"
    fi
  else
    echo " 未发现运行记录。"
  fi
}

# =======================
# 查看状态
# =======================
status_app() {
  if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
    echo "✅ $APP_NAME 正在运行 (PID: $(cat $PID_FILE))"
  else
    echo "❌ $APP_NAME 未运行。"
  fi
}

# =======================
# 查看日志
# =======================
log_app() {
  if [ -f "app.log" ]; then
    tail -f app.log
  else
    echo " 暂无日志文件。"
  fi
}

# =======================
# 卸载
# =======================
uninstall_app() {
  read -p " 确认要卸载 $APP_NAME 吗？这将删除依赖和数据！(y/N): " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    stop_app
    echo "🧹 正在清理环境..."
    rm -rf __pycache__ app.log $PID_FILE
    echo "✅ 已卸载。"
  else
    echo "取消操作。"
  fi
}

# =======================
# systemd 自启动管理
# =======================
enable_autostart() {
  if [ ! -f "$SERVICE_FILE" ]; then
    sudo bash -c "cat > $SERVICE_FILE <<EOF
[Unit]
Description=$APP_NAME Service
After=network.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$WORKDIR
ExecStart=$WORKDIR/../run.sh start_app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    sudo systemctl daemon-reload
  fi
  sudo systemctl enable eduky-monitor
  sudo systemctl start eduky-monitor
  echo "✅ 已启用 systemd 自启动"
}

disable_autostart() {
  if [ -f "$SERVICE_FILE" ]; then
    sudo systemctl stop eduky-monitor
    sudo systemctl disable eduky-monitor
    echo "✅ 已禁用 systemd 自启动"
  else
    echo "未检测到 systemd 服务文件"
  fi
}

# =======================
# 命令行参数支持
# =======================
if [ $# -gt 0 ]; then
  case "$1" in
    start_app) start_app; exit 0 ;;
    stop_app) stop_app; exit 0 ;;
    status_app) status_app; exit 0 ;;
    enable_autostart) enable_autostart; exit 0 ;;
    disable_autostart) disable_autostart; exit 0 ;;
    *) echo "❌ 未知参数 $1"; exit 1 ;;
  esac
fi

# =======================
# 菜单
# =======================
menu() {
  while true; do
    clear
    echo -e "${GREEN}=== $APP_NAME 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 克隆/进入仓库${RESET}"
    echo -e "${GREEN}2) 安装依赖${RESET}"
    echo -e "${GREEN}3) 启动服务${RESET}"
    echo -e "${GREEN}4) 停止服务${RESET}"
    echo -e "${GREEN}5) 查看状态${RESET}"
    echo -e "${GREEN}6) 查看日志${RESET}"
    echo -e "${GREEN}7) 卸载${RESET}"
    echo -e "${GREEN}8) 启用 systemd 自启动${RESET}"
    echo -e "${GREEN}9) 禁用 systemd 自启动${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "$(echo -e ${GREEN}请选择: ${RESET})" choice
    case "$choice" in
      1) clone_repo ;;
      2) install_app ;;
      3) start_app ;;
      4) stop_app ;;
      5) status_app ;;
      6) log_app ;;
      7) uninstall_app ;;
      8) enable_autostart ;;
      9) disable_autostart ;;
      0) exit 0 ;;
      *) echo-e "{GREEN}❌ 无效选项。${RESET}" ;;
    esac
    echo -e "{GREEN}按回车继续${RESET}"
    read
  done
}

menu
