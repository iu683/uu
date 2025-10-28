#!/bin/bash
# ========================================
# EDUKY-Monitor 一键管理脚本
# ========================================

APP_NAME="eduky-monitor"
APP_DIR="/opt/$APP_NAME"
VENV_DIR="$APP_DIR/venv"
SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
LOG_FILE="$APP_DIR/logs.log"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
  clear
  echo -e "${GREEN}=== EDUKY-Monitor 管理菜单 ===${RESET}"
  echo -e "${GREEN}1) 安装${RESET}"
  echo -e "${GREEN}2) 前台开发模式${RESET}"
  echo -e "${GREEN}3) 后台生产模式启动${RESET}"
  echo -e "${GREEN}4) 查看后台状态${RESET}"
  echo -e "${GREEN}5) 查看日志${RESET}"
  echo -e "${GREEN}6) 停止后台服务${RESET}"
  echo -e "${GREEN}7) 启用开机自启${RESET}"
  echo -e "${GREEN}8) 禁用开机自启${RESET}"
  echo -e "${GREEN}9) 卸载${RESET}" 
  echo -e "${GREEN}0) 退出${RESET}"
  read -rp "$(echo -e ${GREEN}请选择: ${RESET})" choice
  case $choice in
    1) install_app ;;
    2) dev_mode ;;
    3) prod_start ;;
    4) prod_status ;;
    5) view_logs ;;
    6) prod_stop ;;
    7) enable_autostart ;;
    8) disable_autostart ;;
    9) uninstall_app ;;  
    0) exit 0 ;;
    *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
  esac
}

uninstall_app() {
  read -rp "确定要卸载 EDUKY-Monitor 吗？此操作不可逆 (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # 停止并禁用服务
    sudo systemctl stop $APP_NAME 2>/dev/null
    sudo systemctl disable $APP_NAME 2>/dev/null
    sudo rm -f $SERVICE_FILE

    # 删除应用目录
    rm -rf "$APP_DIR"

    # 重新加载 systemd
    sudo systemctl daemon-reload

    echo -e "${GREEN}✅ 已卸载 EDUKY-Monitor${RESET}"
  else
    echo -e "${YELLOW}取消卸载${RESET}"
  fi
  read -p "按回车返回菜单..."
  menu
}


install_app() {
  # 检查 python3 是否安装
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${RED}❌ 未检测到 Python3，请先安装 Python3${RESET}"
    read -p "按回车退出..."
    return
  fi

  # 检查 python3-venv 是否安装，如果缺少就提示用户手动安装
  if ! python3 -m venv --help >/dev/null 2>&1; then
    echo -e "${RED}❌ 系统缺少 python3-venv，虚拟环境无法创建！${RESET}"
    echo -e "${YELLOW}请使用以下命令安装（根据你的 Python 版本替换）：${RESET}"
    echo -e "${YELLOW}sudo apt update && sudo apt install python3-venv -y${RESET}"
    read -p "安装完成后按回车继续..."
    return
  fi

  mkdir -p "$APP_DIR"
  if [ ! -d "$APP_DIR/.git" ]; then
    git clone https://github.com/eduky/EDUKY-Monitor.git "$APP_DIR"
  fi
  cd "$APP_DIR" || exit

  # 创建虚拟环境
  python3 -m venv "$VENV_DIR"
  if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo -e "${RED}❌ 虚拟环境创建失败，请检查系统依赖${RESET}"
    read -p "按回车返回菜单..."
    menu
    return
  fi

  source "$VENV_DIR/bin/activate"

  # 安装依赖
  pip install --upgrade pip
  pip install -r requirements.txt

  echo -e "${GREEN}✅ 安装完成${RESET}"
  echo -e "${YELLOW}🌐 Web UI 地址: http://localhost:5000${RESET}"
  echo -e "${YELLOW}默认账号: admin / admin123${RESET}"
  read -p "按回车返回菜单..."
  menu
}



dev_mode() {
  cd "$APP_DIR" || exit
  source "$VENV_DIR/bin/activate"
  python main.py
}

prod_start() {
  cd "$APP_DIR" || exit
  source "$VENV_DIR/bin/activate"
  nohup python main.py > "$LOG_FILE" 2>&1 &
  echo -e "${GREEN}✅ 后台启动成功，日志: $LOG_FILE${RESET}"
  read -p "按回车返回菜单..."
  menu
}

prod_status() {
  ps aux | grep main.py | grep -v grep
  read -p "按回车返回菜单..."
  menu
}

view_logs() {
  tail -f "$LOG_FILE"
  read -p "按回车返回菜单..."
  menu
}

prod_stop() {
  pkill -f "python main.py"
  echo -e "${GREEN}✅ 已停止后台服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

enable_autostart() {
  sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=EDUKY-Monitor Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable $APP_NAME
  sudo systemctl start $APP_NAME
  echo -e "${GREEN}✅ 已启用开机自启并启动服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

disable_autostart() {
  sudo systemctl stop $APP_NAME
  sudo systemctl disable $APP_NAME
  echo -e "${GREEN}✅ 已禁用开机自启并停止服务${RESET}"
  read -p "按回车返回菜单..."
  menu
}

menu
